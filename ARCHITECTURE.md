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
- **Fast recall without exfiltration**: An opt-in on-device index over files, mail, messages, calendars, and reminders makes everyday questions fast — chunked, keyword-searchable, and optionally vectorized — while live reads remain the freshness fallback. Nothing is indexed until the owner turns it on.
- **Durable goals over one-shot prompts**: The agent holds long-horizon goals — a plan, step statuses, an event log, and a cadence — and keeps working toward them between conversations. A goal is a first-class entity; the scheduler merely executes toward it.
- **Proactive, but interrupt-worthy**: Background completions are gated by a surfacing judgment so notifications stay rare enough to be trusted, while run history and the approvals inbox record everything regardless.
- **One switch per capability**: something that only runs when its tool is invoked is enabled in exactly one place — the tool toggle. A second enablement gate in config is a bug, not a feature.
- **Quiet green over alarm fatigue**: a healthy engine earns silence. The System Pulse reads green only while every recorded verifier passes, yellow degrades with bounded reasons behind a disclosure, and red parks fail-closed with one inbox item. The color always means right now — red clears on a fresh passing snapshot, never on timer expiry, and an unanswered probe never clears anything.

**Quiet green is the default posture.** The owner should be able to trust the dot without reading logs: green interrupts no one, yellow discloses its bounded reasons only when asked, and red raises exactly one inbox item instead of a flood. Because every red clears only on a fresh passing snapshot — never because a timer expired, never because a probe went unanswered — the pulse color can never lag the system it reports on.

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
│  │ Push-to-talk │  │ Signal-only  │  │  Chat + goal chip  │    │
│  │ TTS playback │  │ menu bar;    │  │  Approvals Inbox   │    │
│  │ Notifications│  │ routes only  │  │  Goals/Schedules/  │    │
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
│  │  │ Short-term  │  │  AccessRule  │  │  Cron/poll & │  │    │
│  │  │ Long-term   │  │  scopes;     │  │  event trigs │  │    │
│  │  │ Vector +    │  │  deny        │  │  GoalEngine  │  │    │
│  │  │ Structured  │  │  outranks    │  │  Ideas       │  │    │
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
│  │  │  (policy.toml)  │  (2 invariants)  │  │  (api.request)  │    │
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

The Document Index is not a separate process: it is an actor-backed local store inside the core engine, sitting beside the other Support Services and feeding `memories.recall`. See Component Details §14. Goals, the proactive surfacing gate, the Ideas engine, and multi-agent fan-out are likewise actor-backed sub-systems inside the core engine rather than separate processes. The declarative policy engine (§15) is the third such in-process security subsystem: policy store, invariant verifier, and egress supervisor are all actors in the core engine. File-write review is likewise in-process: staged and live review state persist in `episodes.db` beside these subsystems (§16).

The verified-pulse stack is the next family of in-process actor-backed subsystems, none of which is a separate process and none of which reaches the world through a new transport. `SystemHealthSnapshot` (Core actor) fuses subsystem probe completions, the live policy posture read fresh from the shared `PolicyStore`, and sovereign ledger ceremonies into the closed green/yellow/red verdict served on `GET /health` and pushed over the existing hub as `health_updated` (§13). `SovereignLedger` (Core actor) verifies the primary episode ledger against a hash-chained sovereign copy plus an Enclave-signed checkpoint, with its own durable sidecars under `~/.runeweaver/` (§15). `BehaviorWatchdog` (Core actor) counts trusted-tool outcomes and files one brake card through the existing approvals inbox (§5). `SemanticAnswerCache` (Core actor) replays pure Q&A answers from in-memory state that starts empty at every boot (§4). `SecurityProbeSuite` (Core) runs the periodic verifier suite at boot, on policy writes, on the nightly tick, and on-demand (§15). The scheduled-send registry shares the `SchedulerStore` actor beside job scheduling, with rows persisted in `episodes.db` (§7).

Shipped tool set: Email IMAP/SMTP (`email.search`, `email.read`, `email.attachment`, `email.send`, `email.listMailboxes`, `email.move`), web + browser (`web.search`, `web.fetch`, `browser.navigate`, `browser.act`, `api.request`), files (`files.read`, `files.grep`, `files.glob`, `files.list`, `files.write` — writes are reviewable; §16), memory (`memories.store` and `memories.recall`), Apple Messages (`messages.search` read-only, `messages.read` read-only, `messages.send` approval-gated with dry-run preview), media automation (`media.arr` approval-gated plus `media.arr.read` read-only), desktop perception and control (`desktop.screenshot` read-only plus `desktop.action` approval-gated; always registered but fail-closed), goals (`goal.create` approval-gated plus `goal.status`/`goal.progress` read-only), multi-agent fan-out (`fanout.run` approval-gated), and calendar plus reminders (`calendar.search`, `calendar.create`, `calendar.update`, `calendar.delete`, `reminders.search`, `reminders.create`, `reminders.update`, `reminders.delete` — search paths read-only, mutations approval-gated, backed by per-domain EventKit gateways).

### Engine-to-Service Shift

The core engine runs as a local service that UIs drive through one HTTP surface; no terminal loop runs turns beside it.

- **Vapor API layer**: A Vapor service fronts the core engine and exposes chat, health, tools, memory, approvals, runs, scheduler, goals, ideas, and settings operations as JSON routes. The service launches from the CLI binary via `rune-weaver serve`, which builds a `ServerContext` with `ServerContext.make(...)`, or boots embedded inside the menu-bar app.
- **WebSocket event hub & real-time streaming**: The service maintains `/ws` managed by `WSHub`. Chat turns stream text deltas, tool invocations, and outcomes tagged by `sessionID`; in-flight turns support mid-turn cancellation via WebSocket or REST, aborting via `ActiveTurnTracker`. Scheduler, goal, and idea events broadcast on the same hub (`run_started`/`run_completed`, `goal_updated`, `proactive_message`). Every run row kind — chat, scheduler, goal, index, `fanout`, and `fanout_worker` — broadcasts `run_started`/`run_completed` through `WSHub.broadcastRun`; there is no silent run write, and dashboards never depend on polling alone to see a run start or settle.
- **Authoritative concurrent-turn cap**: `ActiveTurnTracker.maxConcurrentTurns = 3` bounds simultaneous chat turns. `GET /health` advertises the cap and the live SearXNG start flight.
- **Durable SQLite persistence for scheduler, goals & run history**: Jobs, run logs, goals, goal steps/events/triggers, and ideas persist in `episodes.db`. `config.toml` jobs are bootstrap seed only when the database has zero jobs. Session rows additionally carry an optional `parent_session_id` fan-out lineage link (best-effort additive column).
- **Run cancellation (shipped)**: `POST /runs/:id/cancel` cancels any running row by run-log row id — one running worker or a whole swarm for `fanout`/`fanout_worker` rows via the engine registry, and any other running row via cooperative `ActiveTurnTracker` cancel plus `steeringQueue.clear` for the row's session, settling the row to `cancelled` with a hub broadcast; affected subtasks and rows settle to `cancelled` and the Runs tab refetches. No new transport.
- **Static dashboard bundle**: Served by the engine itself with chat, grouped nav (Dashboard, Chat, Inbox, Work → Goals/Schedules/Runs, Memory), the approvals Inbox, run history, and index status surfaces.
- **Same trust boundary**: Every service-triggered write still flows through the permission gate. The service adds transport; it does not bypass approvals.
- **Single-owner bearer auth & sliding durable sessions (shipped)**: Exactly one owner token guards the engine HTTP surface. Browser clients exchange it via `POST /auth/session` for an `rw_session` cookie — `HttpOnly`, `SameSite=Strict`, `Max-Age` 24h — whose lifetime slides with activity: any authenticated REST request refreshes both the cookie and the server-side `lastSeenAt` (refresh throttled to once per 5 minutes), and a session dies only after 24h with zero requests (no absolute cap). Session state is keyed by SHA-256 digest of the session token and persisted digest-only in `~/.runeweaver/auth-sessions.json` (0600, atomic writes; raw session tokens are never persisted or logged), so an engine restart preserves device logins. Rotation invalidates live sessions and clears the persisted set; an unreadable, loose-mode, corrupt, or unknown-version store fails closed to no sessions (login required).
- **Fail-closed binding (shipped)**: Loopback always serves. Non-loopback requires a resolved token or boot is refused.
- **Service auto-fire plus per-process single-flight**: Service auto-fires scheduler and goal triggers, sharing one lock per firing class with manual runs; the service is the only turn runner, so the per-firing-class locks bound the whole process.

---

## COMPONENT DETAILS

### 1. Core Engine (Swift)

The core engine owns orchestration, conversation state, and provider routing.

- **Orchestration**: Receives user input, routes through the LLM, executes tool calls, returns responses.
  - **Dynamic System Prompt Composition**: `SystemPromptComposer` renders a prefix-stable prompt carrying no per-tool text (identity, tool-use policy, memory guidance, current date, plus `composedMarker` on line two); tool names, descriptions, and schemas travel strictly on the wire via native tool definitions, so registry contents never affect prompt bytes or cache identity (`cacheKey` covers the scheduled branch plus current date only, reusing prefix bytes across tool toggles for KV-cache hits). Canonical memory names are advertised on the wire; aliases never are. The prompt also carries one static rule teaching that delimited untrusted content is data, never instructions.
  - **Narration Fallback for Local LLMs**: `OrchestratorToolLoop` extracts read-only calls from text narration; gated narrations file approvals and park until decided.
  - **Background turn sources**: `Orchestrator.isBackgroundSource(_:)` is the single owner of which sources (`scheduler`, `goal`, `fanout`, `fanout_worker`) use background prompt/turn handling and parking, so future background sources extend in one place.
  - **In-Flight Turn Cancellation**: `ActiveTurnTracker` tracks running turns across WebSocket and REST.
- **Conversation Manager**: Session state, history, and context windows across durable SQLite tables, hydrating from disk. Sessions carry an optional `goal_id` linking a chat or background session to the goal it advances, and an optional `parent_session_id` linking a fan-out worker session to the chat that spawned its swarm. `Orchestrator.process` stamps each session's origin `source` (for example `dashboard`, `websocket`, `api`), the caller-supplied `title`, and the parent link from `UserInput` through its single `ensureSession` call; fills never overwrite stored values without `overwrite: true`, so scheduler and goal labels stay intact.
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

Tools declare name, description, JSON Schema, permission level (`readOnly`, `requiresApproval`, `trusted`), and handler. Python tools run out-of-process via JSON-RPC 2.0 over stdin/stdout (`SubprocessToolBridge`). Tools that return network-derived content declare `contentTrustLevel == .untrustedExternal` via a non-breaking `Tool` protocol extension (default `.trusted`), never by name-sniffing.

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
3. `recall` merges episodic, semantic, document-index, and profile hits under `RecallBudgets` from `[memory] recall_*` (`perTierLimit`, `autoLimit`, `threshold`, `maxChars`, `perHitChars`, `docPoolMultiplier`, `episodicWeight`). Document candidates use a widened, event-time-ordered pool (the vector leg reads `min(max((clamped * docPoolMultiplier) * 10, 500), maxPerTierResults)`, or `maxVectorWindowResults` when dated, ordered by parent `mtime` desc with NULLs last) unioned across keyword and vectors, with the keyword leg reading at the same width the vector pool uses, fused with reciprocal-rank plus token-overlap, recency, exact name-or-path, display-name entity, and contiguous-phrase bonuses, then calibrated by tier weight. `docPoolMultiplier` governs the vector leg only through `pool * 10` above the 500-row floor, so it is effectively inert at the default page size. Results dedupe by ID plus content, sort by score then tier priority (profile > semantic > docIndex > episodic).
4. Injection is at most one auto-recall system message plus at most one starter-pack system message, both placed directly before the last user message via `MemoryEngine.historyWithRecall` (never lead system) to preserve prefix-cache. `RecallStarterPack.build` always supplies `Profile:`, `Index as of:`, and optional `Goal:` lines (trusted verbatim, capped). Recall lines are capped per-hit, carry `[date|path|display_name]` citations, and wrap docIndex plus episodic `Used`-mirror content in the `ContentTrustLabeler` data-only block; trusted tiers pass verbatim.
5. Diagnostics: `recallWithDiagnostics` returns hit IDs, sources, scores, injected chars, and `skippedDocIndex`; `Orchestrator` logs one content-free `RuneWeaverLog.memory.info` line per turn.

**Memory Flow**: user text enters working memory and mirrors clean into episodic (`Used <tool>:` records); context overflow folds into rolling summary; `/remember` captures deterministically; facts persist with vectors and mirror into profile; future turns see routed recall plus starter pack plus live-tool fallback.

**Embeddings**: Via `EmbeddingsBackend` (`apple` default, `provider` opt-in, `none` keyword-only). Failures fall back to keyword; cancellation propagates. Backfill gains vectors for older rows.

**Document recall**: Via `recallDocuments`, pairing FTS chunks with parents through `DocIndexStore.documents(ids:)` with source metadata and `index_as_of` watermark.

**Semantic answer cache (shipped)**: `SemanticAnswerCache` (actor) replays an answer the engine already produced for a question the model alone answered, so a repeated pure question returns instantly with no second provider round trip. Entries key on the normalized query plus the assistant persona plus the serving model, live in memory only, and start empty at every boot. The exclusion rule sits at the turn boundary — `isExcludedTurn(source:executedToolCalls:)` refuses tool turns, approvals, sends, and voice prompts — and because an excluded turn files nothing, no excluded turn can hit either: "never store" implies "never hit". A lookup scores near-duplicate questions at or above the similarity threshold through the injected embeddings backend, with keyword-overlap fallback when no vectors are available. One invalidation primitive (`invalidateOnMemoryWrite`) is the single clear route: durable memory writes call it on every fact, preference, and profile mutation, and goal changes and policy changes route through the same clear, so no partial invalidation path can replay pre-write text. The routine episodic turn mirror deliberately does not invalidate — mirrors land on every turn and carry no fact-level change.

### 5. Permission Gate & Access Rules (shipped)

Levels `readOnly`, `requiresApproval`, `trusted`. `memories.store`/`recall` are `trusted`; `messages.send`, `desktop.action`, `browser.act`, `api.request`, `media.arr`, `goal.create`, `fanout.run`, and `files.write` require approval. Goal ledger bookkeeping (`goal.status`, `goal.progress`) is `readOnly` — the same bargain as `memories.store`: it mutates only the local ledger, never the world. Every action a goal step or fan-out worker takes while advancing still flows through the permission gate exactly like any other turn — no bypass for background work. Declarative egress supervision (§15) is layered beneath this gate for `api.request` and never relaxes it: approval is still required, and the supervisor can deny on top of any approval.

**Access rules — the durable trust model**: one rule = (`toolName`, `AccessScope`, `AccessAction`, `duration`) (`AccessRule.swift`, Core). `AccessScope` is one of `toolWide`, `exactTarget(String)`, `recipientSet([String])`, `domain(host:subdomains:)`, `pathPrefix(String)`, or `glob(String)`; `AccessAction` is `allow` or `deny`; `duration` is nil for a standing rule that never expires or one of `fiveMinutes`, `oneHour`, `oneDay`, `forever`. `exactTarget` carries the legacy target string and is the only matcher that reproduces pre-migration `trust_grants` matching byte-for-byte, so a migrated rule keeps covering exactly the call the owner approved. Spelling is owned per shape — recipient sets by `AccessScope.normalizeRecipients`, domain shape by `AccessScope.canonicalDomain`, path shape by `AccessScope.canonicalPathPrefix`, glob shape by `AccessScope.canonicalGlob` — and `AccessScope.matches(toolName:argumentsJSON:)` is the single owner of scope matching; no other file re-implements the comparison. A rule with a malformed or unrecognized scope is rejected at creation and never matches at evaluation. `thisTime` stores nothing, and the task and session tiers are `EphemeralGrant`s instead of rules: they live in memory beside the gate, die on their owning task's or session's lifecycle boundary, and never persist — their trust is visible only for the turn or conversation that earned it (readable via the session-trust route, cleared by `POST /approvals/ephemeral/clear`).

**Gate decision order** (`PermissionGate.checkPermission`), highest first: (1) a durable deny rule covering the call returns `.denied(reason)` naming the rule scope; (2) non-read-only edits of protected engine paths refuse; (3) egress host status decides — explicitly blocked refuses, an unlisted host parks an approval; (4) `readOnly`/`trusted` tools run; (5) `bash.exec` evaluates the shell policy (deny refuses, allow runs, ask continues); (6) `files.write` resolves its write posture through `WritePathPolicy` (§16) — deny refuses, stage and live proceed into the tool's own review flow with no approval request filed, ask parks; (7) ephemeral task and session grants may cover the call; (8) durable allow rules may cover the call; (9) anything left parks for approval. **Deny outranks**: the durable deny is evaluated before any grant coverage, carries `expiresAt` nil forever, and is removed only by explicit revoke. No allow rule overrides, shortens, or evicts a deny rule for the same scope, and widening never promotes a deny. A deny rule is minted only by an explicit owner decision (approved=false plus forever) or by `PermissionGate.denyRule(scope:toolName:reason:)`.

**Unified decision contract**: `POST /approvals/:id/decide` with body `{approved, duration, scope}` is the only decision path; the chat inline banner, the Inbox, the dashboard quick actions, and WebSocket triage all send it. For egress-parked requests (`pending.egressHost != nil`) the mapping is: approved=true plus `thisTime` calls `OutboundEgressSupervisor.allowDomainOnce`; approved=true plus `forSession` calls `allowDomainForSession`; approved=true plus `forever` mints a durable allow rule scoped `domain(host)`; approved=false plus `thisTime` denies the call only; approved=false plus `forever` mints a durable deny rule scoped `domain(host)` and calls `PolicyStore.appendBlockedDomain`. For every other request: approved=true plus a non-`thisTime` duration mints a durable allow rule with the resolved scope; approved=false plus `forever` mints a durable deny rule; approved=false plus `thisTime` denies the call only. `engine.continue`, `question.ask`, `desktop.resume`, and `behavior.brake` are coerced to `thisTime` with no stored rule inside `ApprovalQueue.decide(id:approved:duration:scope:)` — they resolve one parked batch rather than gating a repeatable call. A `messages.send` scope must be `recipientSet` or an `exactTarget` naming a canonical handle; any other send scope stores nothing and the call fails closed at execution.

**Behavior brake — trusted-tool watchdog (shipped)**: `BehaviorWatchdog` (actor) is the anomaly brake over the trusted tools. It records only counts — tool name, session, and outcome category (executed, denied, firewall-blocked) — and never an argument, a prompt body, or model output, so neither its live state nor its persisted baselines can hold content. Rules (`rate_spike`, `denial_spike`, `off_hours`, `firewall_spike`) evaluate the trailing window against a learned baseline; the watchdog stays silent through its quiet-learning gestation because an unarmed baseline has nothing to compare against. When a rule fires, the brake parks every running turn through the same cooperative cancel contract `ActiveTurnTracker` already owns for REST and WebSocket, clears each parked session's steering, and files one numbers-only card (`behavior.brake`) into the existing approvals inbox — idempotent while engaged, so one anomaly yields one card instead of a flood. The watchdog never auto-remediates and never approves: a "keep paused" decision leaves every turn parked exactly as the owner left it, and clearing the brake is an explicit owner Resume — the dedicated Inbox branch (§13), reached through the same decision contract — that resets the trailing counters so the just-observed spike cannot immediately re-fire. It never clears on a timer.

### 6. Secrets Manager & Surrogation (shipped)

Keychain primary, Docker vault optional, `config.toml` for non-sensitive settings only. Secrets never enter logs, prompts, or index.

**Credential surrogation**: `api.request` header values may reference `rwsecret:<key>` surrogates. `SecretsManager` issues (`surrogate(for:)`), resolves (`resolve(_:)`), and sweeps (`redactResolved(_:)`) them. Resolution happens just-in-time at the transport boundary so the real value is never model-visible; the surrogate is a reference, not a copy, and dry-run previews never show the real value. A surrogate with inner whitespace is rejected so issuance and resolution agree. `ApiHeaderPolicy.redacted` also redacts any resolved secret values that echo into outputs. Surrogate resolution is now performed under the mandatory `OutboundEgressSupervisor` choke-point (§15), which also sweeps responses for echoed secrets.

### 7. Scheduler, Goals & Run Execution Engine (shipped)

Cron plus polling plus goal cadence and event triggers, with SQLite as source of truth. Per-run sessions (`source: scheduler` or `source: goal`) with fresh `UUID()` per execution, parked `awaiting_approval` resume through the inbox, and per-firing-class single-flight per process (a dedicated goal run lock so goal and job firings never collide). Downtime semantics: `next_due_at` drives firing; there is no catch-up stacking after a long sleep — a skipped-while-down firing simply re-dueues on the next interval. Each run persists a `run_logs` row (`kind` = `scheduler`, `goal`, `fanout`, or `fanout_worker`) linked to its session and, where applicable, its goal; every row write broadcasts through the hub, with fan-out rows riding the dedicated `FanOutRunLogAdapter` (§11).

**Event triggers**: `goal_triggers` rows (goal id, event kind, optional substring pattern, cooldown, last-fired) arm a goal for event wake-up. `GoalTriggerBridge` runs in the worker tick, polls recent goal and episode events within a bounded lookback, and on a kind/pattern match whose cooldown has elapsed sets `next_due_at = now`. The existing due-firing path then picks it up unchanged. The bridge stays event-kind-agnostic so future event sources extend in one place; there is no catch-up stacking (one match per cooldown window).

**Scheduled sends (shipped)**: an owner schedules a delayed email or Messages send from the Schedules surface. At the approval moment the exact bytes, the recipient, and the fire time are stored immutably as one `ScheduledSend` row beside scheduler jobs in `episodes.db`; `email.send`/`messages.send` themselves always send immediately on approval and refuse a fire time with guidance toward the scheduler. The fire worker claims due rows exactly once through the queued-to-sending transition — a second tick while a row is `sending` never returns it — then replays the stored bytes through the owning send tool with re-validation and no LLM regeneration, so what ships is exactly what the owner approved. A recipient that went stale, a policy refusal, or a transport failure settles the row `failed` with the reason as its Runs note rather than shipping something the owner never approved. Cancelling or editing a booked send needs a fresh approval, because the stored payload is the approved artifact; a send that aged past its grace window during downtime settles `failed` with its skip reason instead of stacking catch-up fires. Each fire and skip writes a `run_logs` row and broadcasts through the hub like every other run.

### 8. Goals Subsystem (shipped)

Goals are durable first-class entities: each owns a plan (ordered steps with statuses), an event log, and a cadence. State lives in `episodes.db` (`goals`, `goal_steps`, `goal_events`, `goal_triggers`), opened via the shared Core store idiom with additive, best-effort migrations (`sessions.goal_id`, `run_logs.goal_id`).

- **Model**: `GoalStatus` (`active`, `paused`, `needs_input`, `achieved`, `abandoned`, `unplanned`), `StepStatus` (`pending`, `inProgress`, `done`, `blocked`, `skipped`), `GoalEventKind` (`created`, `planReady`, `stepStarted`, `stepDone`, `stepBlocked`, `needsInput`, `completed`, `resumed`, `paused`, `note`). New goals start in `unplanned` with an empty steps array; the active-goal cap counts `active` plus `unplanned`. `GoalStore` is an actor behind a `GoalStoring` seam; `nextActionableStep` deterministically selects the lowest-ordinal pending/in-progress step.
- **Engine**: `GoalEngine` (actor) with an injected LLM. `create` enforces `[goals] enabled` plus the active-goal cap, persists the goal in `unplanned` with empty steps, then decomposes via ONE LLM call bounded to `maxStepsPerGoal` and `planTimeoutSeconds` (`0` means unlimited, otherwise `0…86400`). Defensive parse (strip fences, outermost array); on cancel, parse failure, or timeout it settles to `unplanned` with empty steps plus a note — no placeholder step and no fallback step — so a flaky plan stays retryable instead of inventing work. `postAdvance` re-reads steps after the turn and, when no actionable step remains, marks the goal achieved; the cadence advances `next_due_at`.
- **Advance composition**: dynamic goal state never enters the cached system-prompt prefix. `advancePrompt(goal:steps:events:)` composes the per-run prompt into the `UserInput` text (plan with statuses, last 5 events, instructions to advance exactly one step and record blockers honestly).
- **Firing**: an ordinary orchestrator turn with a fresh per-run session (`source: "goal"`, `goal_id` stamped), a `run_logs` row `kind="goal"`, WSHub broadcast, and parked `requiresApproval` turns resuming through the inbox. No bypass of the permission gate.
- **Tools**: `goal.create` (`requiresApproval` — commits recurring autonomous work) and `goal.status`/`goal.progress` (`readOnly` ledger bookkeeping). `goal.progress` resolves the current session's linked goal, falls back to the single active goal, and returns typed guidance on ambiguity rather than guessing.
- **REST**: `GET /goals` (status filter), `POST /goals`, `GET /goals/:id`, `PATCH /goals/:id` (edits + pause/resume), `DELETE /goals/:id` (abandoned tombstone; `?purge=true` hard-delete), `POST /goals/:id/advance` (single-flight contention → `409`), `PATCH /goals/:id/steps/:stepId`, `GET /goals/summary`. Emits `goal_updated` WS frames on create/plan-ready/progress/status-change/advance.
- **Surfaces**: the dashboard (see §13).

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

`FanOutEngine` (actor) behind a narrow `OrchestratorFanOutSeam` spawns concurrent worker turns for a set of caller-composed subtasks. Each worker gets a fresh per-run session stamped with `source: "fanout_worker"`, the subtask title, and `parentSessionID` pointing at the originating chat, a read-only tool subset via `UserInput.allowedTools` (nil = full registry; `fanout.run` passes the read-only names unless `[fanout] full_tools`), and `run_logs` rows — a `kind="fanout"` parent plus `kind="fanout_worker"` children — so the swarm is fully auditable in the Runs tab and nestable in chat history. Workers fan out via a `TaskGroup`; if the orchestrator serializes concurrent turns, workers stay sequential-but-bounded rather than forcing a core rewrite.

**Live audit broadcasts**: fan-out row writes ride the server's `FanOutRunLogAdapter` — the shared `RunLogStore` paired with the `WSHub` — so parent and child rows emit the same `run_started`/`run_completed` frames as chat and scheduler runs. The prior store-only `FanOutRunLogging` conformance is deleted: there is exactly one broadcast path, and no fan-out write can stay silent.

**Enablement (single gate)**: fan-out has no background entry point — a swarm runs only when the `fanout.run` tool is invoked — so the persisted tool-state toggle is the sole enablement authority. The tool ships disabled and appears in `GET /tools`; `[fanout]` carries only behavior knobs (`max_workers` default 2, `worker_timeout_seconds` default 0 = unlimited, `full_tools` default false) and no enablement key. Settings → Tools configures the knobs with live reload. `fanout.run` stays `requiresApproval` (it spawns autonomous work): approval is the per-call permission, separate from enablement.

**Timeout**: `worker_timeout_seconds = 0` means no wall-clock budget, because a local model serving a worker turn can take minutes and a short default would kill workers mid-turn. Owners may set a positive budget (clamped 1–86400s); the bound on an unbounded worker is owner cancellation, not a timer.

**Cancellation (cooperative, engine-owned)**: the engine keeps an active-run registry keyed by the run-log row ids it mints. `POST /runs/:id/cancel` cancels one running worker (child row) or the whole swarm (parent row); a cancel arriving before a worker registers is remembered and applied at registration, so there is no start race. Cancellation propagates Task cancellation to the worker's orchestrator turn — the same cooperative contract as the chat window — and a worker that ignores cancellation still ends when its current await returns; nothing is force-killed. Chat's existing per-tool cancel aborts the whole `fanout.run` call and now also yields honest statuses. Any other running row cancels through the same cooperative contract — `ActiveTurnTracker` cancel plus `steeringQueue.clear` for the row's session, then the row settles to `cancelled` with a `run_completed` hub broadcast.

**Statuses**: `FanOutSubtask.Status` and `FanOutRun.Status` include `cancelled`, and the child/parent run rows use the existing `cancelled` run status. Cancellation outranks failure for the owner's reading (a stopped swarm reads `cancelled`, not `error`), while sibling workers keep running when only one is cancelled.

**Merge**: deterministic overlap detection first (exact file-path/URL collisions between outputs are flagged conflict), then ONE background reviewer LLM pass over the collected outputs producing a merged summary plus per-subtask verdicts (keep/drop/conflict). The reviewer judges content quality, not permissions. Fail-open: a reviewer error yields the raw concatenation with an honest note, so worker output is never lost. An all-cancelled run skips the reviewer and carries a short honest summary.

### 12. Voice Pipeline (partial)

Local Whisper STT, system TTS; push-to-talk planned.

### 13. Client Layer

**macOS App — shipped**: a signal-only menu bar. The indicator carries a single prioritized mark — failed bind (distinct octagon) over pending-approval count over boot/restart progress over desktop over indexing over idle — and the menu reports rather than decides: Open Web Dashboard, one row per active chat, an "Attention required (n)" row that routes to the dashboard Inbox, scheduler next/last summary, an Indexing section only while a run is in flight, and the Desktop Control section while a batch is active or paused waiting for operator resume (armed-but-idle stays hidden; Emergency Stop while active, Open Inbox while paused). The menu bar owns no approve/deny control — every request kind, including `question.ask` and `desktop.resume`, decides in the dashboard Inbox through the shared decision contract. Native notifications are informational: an approval-attention post names only the tool and its severity (no description, no arguments, no category, no actions), so no decision can originate there, and its tap deep-links to the dashboard Inbox; scheduler completions carry the Open Dashboard action. Owner Access (token status plus Rotate), Permissions onboarding, and Settings stay reachable from the menu.

**Web Dashboard — shipped**: chat with session sidebar — fan-out worker sessions nest beneath the chat that spawned them behind a collapsed-by-default disclosure (branch icon, agent-count chip; expansion is ephemeral and the active child's parent stays open; orphans surface top-level) and history revalidates on coalesced `run_started`/`run_completed` frames (750 ms), Chat-tab activation, document visibility regain, and socket reopen — plus clock-badged background sessions, memory, run history (with fan-out worker grouping and cancel controls for running swarms), the approvals Inbox (pending requests only, grouped — see below), index status, tools config (including the fan-out run policy with live apply), Settings → Access (standing rules plus the declarative policy editors, §15), goals management, and an ideas panel. Navigation is grouped — **Dashboard**, **Chat**, and **Inbox** stand alone as direct views (with **Dashboard** as the primary operations landing surface); **Work** groups Goals/Schedules/Runs; **Memory** groups Search and Memory plus Index Status — using click/keyboard-only dropdown mechanics (click-toggle, click-outside, Escape closes and returns focus, `aria-haspopup`/menu; no hover-open path). The active goal is surfaced inline in chat as a header chip that opens a right-side `GoalDrawer` (plan checklist, recent events, linked runs, pause/resume, advance-now, "Open in Goals"). A `goal_updated` WS frame refreshes the chip/summary list; `proactive_message` raises a Web Notification with the headline and bumps the goals-attention badge (which clears when the Goals tab opens), falling back to badge-only when notification permission is absent. All model-authored content renders through the sanitized `MarkdownText` (zero `dangerouslySetInnerHTML`, protocol-whitelisted URLs). File writes render as reviewable diff cards in chat and in the single-column Staged Changes drawer — collapsed by default behind a chevron (chat setting "File Write Cards"), hydrated from `POST /files/review-status`, with only the newest pending write per file owning Accept/Discard (§16).

**Inbox grouping (approvals — pending requests only)**: standing rules live in Settings → Access. Grouping is by `sessionID` with sticky session headers titled from `GET /sessions`; unattributed requests (the brake card, older payloads without a session tag, headless filings) group under "Unattributed". Groups order by maximum card severity descending; cards within a group order by severity descending then filing time descending. Severity is `request.assessment.severity` when present and `moderate` when absent. No card is hidden behind a collapsed group, no group-level or bulk approve control exists anywhere, and every card renders its own Allow and Deny controls with the full duration picker and scope editor. The Dashboard NeedsActionQueue quick actions are labeled "Approve once" and "Deny" and every card links "Open in Inbox". Brake cards (`behavior.brake`) are the sole exception: they render a dedicated Resume plus Keep-paused branch with no duration picker and no scope editor, because releasing parked turns is their complete decision.

**Settings → Access (standing rules plus the policy's UI home)**: the owner's "what the agent is allowed to do" surface — a section rail over Rules, Bash & Shell, Network, Credentials, and Files, with Rules the landing section and the target of the Inbox's standing-rules deep link (`#settings?access=rules`) and per-rule deep links. The Rules section lists, creates, revokes, and edits standing rules through an Add Rule / Edit modal instead of per-action row controls — the `/approvals/rules` routes (shapes under DECISIONS & CONSTRAINTS) back it and the section refetches on the `access_rules_changed` broadcast. An edit that changes only an allow rule's duration re-arms the rule in place via `PATCH /approvals/rules/:id`, so the rule's identity and use counters survive; an edit that touches scope, effect, or tool mints the replacement rule first and revokes the original only after the mint is proven stored, so a refused mint leaves the old rule standing for a retry. Widening exists only as the engine's `POST /approvals/rules/:id/widen` route — the section exposes no widen affordance. The declarative policy surface (§15) mounts here: the Network and Credentials rail sections host the structured network and credential editors plus read-only local-exemption display with Re-check plus credential list plus binding modal, invariant-status banner, shared settings-footer Save with live apply and no restart, no in-app raw editor; the browser modal no longer edits origins.

**System Pulse (shipped)**: the dashboard's primary operations card renders the closed verdict served by `GET /health` — `status` is `"green"`, `"yellow"`, or `"red"` only, carried beside the engine identity, the live search posture, and the verified-pulse evidence (`ledgerTip`, `ledgerVerifiedAt`, `policyHash`, `policyVerified`, `probeVerdict`, `degradedReasons`). Green reads Operational and interrupts nothing; yellow opens a Details disclosure listing the bounded reasons; red offers Open inbox / Retry verification / Open Policy actions beside the status. Live updates ride the `health_updated` frame on the existing hub carrying the operational signal only, while the tips stay owner-private on the authenticated REST projection exactly like the boot-bind keys — an unauthenticated probe learns the verdict and the reasons but never a digest. The card re-probes on frame receipt, socket reopen, tab visibility regain, and a heartbeat, and the engine publishes only deep changes against the last served value so steady-state polling stays quiet. A failed probe never moves the pulse: the dashboard clears red only on a fresh passing snapshot, never on a timeout, a fetch error, or a timer. The engine-side snapshot reads the live policy store on every probe, so a policy write surfaces with no restart plus no watcher.

**iOS — planned**.

### 14. Document Index (shipped, opt-in)

Local single-owner pre-built index: pay once, answer from index, fall back to live reads. Off by default with per-source files/mail/messages/calendars/reminders toggles and per-source status surfaced on the dashboard. SQLite `indexed_documents` + `indexed_chunks` + FTS5 porter plus embedding BLOB, content-hash skip, per-mailbox UID and Messages ROWID watermarks, best-effort extraction with status, `BODY.PEEK` mail reads, bounded vectorization (`mail_vector_window`, size rule), nightly plus on-demand `IndexCoordinator` runs with `liveTotals`, `index_as_of` watermark, and prune/reset maintenance. Vector pool width and fusion weights are governed by recall budgets; injected hits always preserve file/mail/messages/calendars/reminders citations so the model can answer with paths and dates without re-walking. Indexed mail is stored in its credential-redacted form so search recall cannot resurrect a redacted link.

### 15. Declarative Security Policy & Outbound Egress Supervision (shipped)

A declarative, owner-editable `~/.runeweaver/policy.toml` owns network (including the manual-only `local_exemptions` set) plus credentials: `[network]` egress boundaries (`allowed_domains`, `blocked_domains`, `local_exemptions` for private-address dialing) plus per-secret `[credentials.<key>]` bindings for `api.request`, `web.fetch`, `browser.navigate`/`browser.act`, `bash.exec`, and `desktop.action`. `FilesystemPolicy` plus `ToolPolicy` are deleted; legacy `[filesystem]` plus `[tools.*]` tables are ignored on load and never written back, so a resaved file sheds them. `EgressMode` lists exactly `allowlist_only` plus `unrestricted`; a legacy `deny_by_default` string parses as `allowlist_only` on load, preserving its fail-closed intent. Two fail-closed actors plus one pure Sendable verifier own it:

- **`PolicyStore`** (actor, `PolicyStore.swift`, Core): the single owner of the policy file. Every load and every update runs `PolicyInvariantVerifier.verify` before the policy is accepted; an unreadable or failing file seeds factory-safe defaults (allowlist-only) rather than permissive ones. `snapshot()` returns the verified in-memory policy or throws — there is no permissive fallback state. Every update verifies, serializes through the store-owned round-trip proof, writes the file first, then commits to memory, so a throwing disk write never diverges memory from file.
- **`PolicyInvariantVerifier`** (pure Sendable enum, `PolicyInvariantVerifier.swift`, Core): three formal security invariants at the storage boundary (on load and on every update) and on demand — (1) **credential confinement**: credentials cannot target forbidden hosts, non-leading wildcard shapes, loopback, link-local, or private ranges, nor cloud metadata hosts (`169.254.169.254`, `metadata.google.internal`); a single leading `*.` edge authorizes its base domain plus subdomains, with the base checked like an exact host; empty host lists are unusable and blank domain entries are rejected; (2) **rule-shadow prevention**: broad `allowed_domains` entries never shadow or conflict with specific `blocked_domains` — a blocked domain always refuses even when an allow entry would otherwise cover it; (3) **local-exemption safety**: every `local_exemptions` entry must be a well-formed exact host, address literal, single leading `*.` edge, or single trailing `.*` edge — blank entries, TOML-breaking scalars, non-edge wildcards, and port-qualified entries are rejected (exemption matching is port-less); bare `*` remains inert at runtime (never matches concrete destinations); and metadata, link-local, and IPv4-embedded translation targets are never-exempt in any spelling while loopback, private, CGNAT, and unique-local hosts stay dialable by design because an exemption exists precisely to reach a local service.
- **`OutboundEgressSupervisor`** (actor, `OutboundEgressSupervisor.swift`, Tools): the multi-consumer choke-point for `api.request`, `web.fetch` (per-hop `validateHopSafety`), `browser.navigate`/`browser.act` (per-entry and per-hop `EgressPolicy.validateURLAsync`), `bash.exec` (explicit plus schemeless `screenExplicitURLs`), and `desktop.action` (typed-URL `screenBatchURLs`). `validate()` gate order: (1) network policy gate (canonicalized exact and wildcard domain match, honoring session and one-shot grants), (2) credential target-binding gate (verify credential host, method, path prefix), (3) SSRF guard (`ApiSSRFGuard`), (4) just-in-time wire injection (swap `rwsecret:<key>` for the live Keychain value), followed by `sweepResponse` redaction of echoed secrets. `validateReadOnly()` applies the same network gate (including grants) plus SSRF with no credential binding and no Keychain access. Network and binding checks run BEFORE Keychain access or DNS resolution, so a denied destination never causes a network side effect. Effective SSRF exemptions are the auto service origins (browser loopback, media LAN, configured LLM server URLs) unioned with the snapshot's owner-asserted `local_exemptions`, read fresh on every call; metadata, link-local, and IPv4-embedded translation targets stay refused even when named. Only the manual settings paths may write `local_exemptions` — triage grants, `appendAllowedDomain`/`appendBlockedDomain`, and every other agent-writable path leave the set untouched and never widen the SSRF set, while owner-configured `local_exemptions` explicitly does. The SSRF gate returns a **dial pin** — the numeric addresses it proved plus the original host identity — and the `api.request` transport (`PinnedDialTransport.swift`) dials only those pinned addresses, presenting the original `Host` header and TLS server name and validating the peer certificate against that host. The hostname is never resolved again after vetting, so a rebinding answer cannot steer a hop to a destination the gate refused; every redirect hop carries its own pin from its own supervised pass, and the transport fails closed when a dial arrives without a pin.

**Production wiring contract**: the supervisor is mandatory at every production entry point. `ApiRequestTool` takes a non-optional supervisor (no default-nil); `BuiltinToolPlugins.makeAllTools(config:policyStore:)` uses exactly ONE `PolicyStore` instance per process (the caller injects it, or the factory constructs it via `PolicyStore.makeLoaded(injected:fileURL:)` where `fileURL` defaults to `nil` for `~/.runeweaver/policy.toml` and allows test harnesses to supply an isolated temporary path), builds the supervisor via `OutboundEgressSupervisor.make(policyStore:)` (which reads the verified `snapshot()` and throws when no verified policy exists), and threads it through `ApiRequestTools.makeTools` plus the web, browser, bash, and desktop tool factories with per-tool session threading. CLI and menu-bar app exit nonzero at boot when the policy cannot be verified — no supervisor-less fallback path exists. The server's `ServerContext.make` always injects a verified supervisor or throws at boot; the context type holds the supervisor as optional only for fallback and test doubles, and `applyEgressDecision` (REST plus WebSocket triage sharing one handler) fails closed when the supervisor is nil. The server's `ServerSettingsRoutes` shares the SAME store instance between the tool-rebuild path and the `GET/PUT/POST /settings/policy` routes, so an HTTP policy write applies live through the shared `PolicyStore` with no restart plus no watcher — the actor state is authoritative within the process and the file is source of truth at first construction; a save-then-GET reflects the write and the supervisor snapshot reflects the write, while an invalid PUT leaves file plus memory unchanged. `PUT /settings/policy` classifies every new or edited exact entry server-side and reports `localAccess` (wire property; mapped from disk `local_exemptions`): an unresolved classification fails the whole write atomically with Abort 400 and leaves file plus memory unchanged. `POST /settings/policy/recheck-local` previews re-classification of the candidate allowlist (added, removed, unchanged, unresolved, plus never-dialable reporting) while wildcard entries keep their stored grant status, and `POST /settings/policy/recheck-local/apply` persists the proposed set and rebuilds browser, web, and API tools live with no restart. `PolicyStore.appendAllowedDomain`/`appendBlockedDomain` verify, serialize through the store-owned round-trip proof, write the file first, then commit to memory, so a throwing disk write never diverges memory from file and those paths never touch `local_exemptions`. Seatbelt profiles deny `~/.runeweaver/policy.toml` to sandboxed subprocesses so policy cannot be altered from inside a sandboxed shell.

**Surfaces**: Settings → Access is the policy's UI home — the Network and Credentials rail sections mount the structured network and credential editors plus read-only local-exemption display with Re-check, credential list plus binding modal, invariant-status banner, shared settings-footer Save with live apply and no restart, no in-app raw editor (changed equals deep compare of the policy DTO against the last loaded snapshot, the pane clears the saved banner on next edit and never shows a restart banner for policy; the browser modal no longer edits origins); CLI `rune-weaver policy verify` is the CLI's only policy responsibility — proving the invariants plus local-exemption safety on demand before the engine boots against the file, with no CLI path seeding, editing, or rewriting it; REST `GET /settings/policy` (structured DTO plus live invariant status, no raw TOML on the wire), `PUT /settings/policy` (server serializes the structured candidate through the store-owned round-trip proof, classifies new or edited exact entries for local access and reports `localAccess`, then validates the invariants and persists; failures return Abort 400 naming the gate plus field and leave file plus memory unchanged), `POST /settings/policy/verify` (structured candidate verification for editors), `POST /settings/policy/recheck-local` (re-classification preview with wildcard grant preservation), and `POST /settings/policy/recheck-local/apply` (persists the re-classified set and refreshes live tools).

**Binding contract**: one binding pairs one key with hosts plus methods plus path prefixes. A request sends the secret iff host matches hosts plus method matches methods-or-Any plus effective path matches prefixes-or-Any. Prefixes apply to every host in the same binding, so scoping is per-key rather than per-host. Empty hosts means unusable; empty methods means Any; empty prefixes means Any. Methods uppercase to `GET`/`POST`/`PUT`/`PATCH`/`DELETE`/`HEAD`/`OPTIONS`; prefixes must start with `/`; key names must satisfy `SecretsManager.isValidSurrogateKey`. TOML-breaking scalars (quotes, C0 controls, DEL) are rejected at the REST and store boundaries so the bytes on disk always reparse to the verified object; unknown `EgressMode` strings map to `allowlist_only` on load and are rejected on the REST boundary; denied stays denied when authenticated.

**Sovereign ledger (shipped)**: `SovereignLedger` (actor, Core) proves the primary episode ledger's history has not been retroactively edited. Primary episodes remain the source of truth; a hash-chained sovereign copy (`~/.runeweaver/memory/ledger.sovereign.jsonl`) and an Enclave-signed checkpoint (`~/.runeweaver/sovereign-checkpoint.json`, HMAC-SHA-256 under a file-backed key at `~/.runeweaver/sovereign-signing.key`) exist to corroborate that truth. A ceremony recomputes the canonical chain from the primary store, strictly decodes and verifies the copy's own linkage (unknown fields, sequence discontinuities, chain breaks, and HMAC mismatches throw rather than conclude), and cross-checks the copy as a prefix of the recomputed chain: agreeing heads verify quiet, ledger growth extends the copy and re-attests, and a broken prefix returns `mismatch` with nothing rewritten. A signed checkpoint older than the staleness bound cannot arbitrate, so the ceremony fails closed. The recorder (`SystemHealthSnapshot`) judges the presented material only — a presented vote must attest the recorded head — and a disagreement latches the pulse red. Re-attestation is an explicit, separate act; a restored copy is corroborated by a verified vote, never silently repaired.

**Periodic security probes (shipped)**: `SecurityProbeSuite` (Core) runs a bounded verifier suite — `traversal`, `symlink-escape`, and `replay` as fail-closed verifiers; `firewall-redaction`, `ledger-integrity`, `zero-socket`, and `vault-round-trip` as degrading ones — against the real guard implementations under a total and per-probe timeout. It runs at serve boot, after a committed policy write (`PUT /settings/policy` and the re-check apply), on the nightly tick, and on-demand — never per tool call. Each report merges into the pulse by verifier name, so a recovered verifier clears on the next passing cycle while an empty report is rejected fail-closed. A moved posture publishes `health_updated` and, when a fail-closed verifier failed, parks exactly one bounded inbox item (`security.probe`) gated by the report-hash compare, so a persistent failure files one item instead of one per run. Boot aborts when a critical verifier fails; non-critical failures record and surface without blocking the bind.

Scope note: `web.fetch` (per-hop `validateHopSafety`), browser `navigate`/`act` (per-entry and per-hop `EgressPolicy.validateURLAsync`), `bash.exec` (explicit plus schemeless `screenExplicitURLs`), and `desktop.action` (typed-URL `screenBatchURLs`) are supervised in this cycle through `OutboundEgressSupervisor.validate` alongside `api.request`, each threading its calling session so interactive grants stay scoped; all keep their existing SSRF/redirect guard stacks (sensitive-range table single-sourced with `api.request`) layered beneath the policy gate. Triage badges the first host while enforcement screens every host, so multi-host batches re-park iteratively; triage never writes `local_exemptions`, so the agent-writable path never widens the SSRF set while owner-configured `local_exemptions` explicitly does. Follow-up: extend declarative credential target-binding beyond `api.request` and unify multi-host badging.

### 16. File Write Review — Staged & Live (shipped)

`files.write` is the reviewable write path: every write either stages for review or lands live under a tracked rollback copy, and both outcomes persist in `episodes.db` so a reloaded client always knows how a review ended.

- **Write-path posture (single owner, single park)**: `WritePathPolicy.classify(path:filesConfig:)` (`WritePathPolicy.swift`, Core) is the single owner of write posture, and `FilesAccessGuard.denyReason` stays the single owner of read-path deny — this policy never answers reads. Precedence, highest first: (1) `WritePathPolicy.alwaysDenyPatterns` union `[files] deny_patterns` glob match → posture deny; (2) the longest matching `[files]` write-path rule entry → its posture; (3) the global `[files] write_mode` (`model` default | `staged` | `live`) — `staged` → stage, `live` → live, `model` → stage when the per-call mode is absent or not live and live when the per-call mode is explicitly live (an unknown explicit mode fails closed), with a forced posture overriding the per-call argument, accepting and ignoring any `mode` a stale schema still sends, and naming the override in the envelope message while the tool's advertised schema and description drop `mode`; (4) a path outside every resolved allow root → ask. Posture `ask` parks an approval request — and that is the only route a write ever takes to a filed request, so one write parks at most once; `stage` and `live` execute the tool with no approval request filed. Every classification runs on the canonical view (tilde-expanded, standardized, symlinks resolved) produced by `WritePathPolicy.canonicalPath`, so a symlinked parent or `..` segment cannot hide the true location. The write-mode selector, the write-path rules table, and the files read-guard editor (allow roots, deny patterns, approval-on-deny) are edited together in Settings → Access → Files — the read-guard editor was re-homed there from Settings → Security so the whole files trust surface (write posture plus read boundary) consolidates in one Access section.
- **Staged review**: `files.write` writes the proposal to a `.rune_<name>` sibling and upserts a pending `staged_files` row (additive `resolution`/`resolved_at` columns; a fresh write clears any prior terminal state). Accept promotes the sibling over the live file; Discard deletes it; a later live write resolves the row `superseded` and removes the sibling. Resolutions only ever transition NULL → terminal, and `list(under:)` returns pending rows only — settled rows survive as tombstones even after their staging file is gone.
- **Live review**: the first live write to an existing path opens a review and snapshots ONE first-wins `.rune_backup_<name>` rollback copy; later writes join the pending review and never touch the copy, so one Accept/Revert settles the whole series. A live write to a new file owns no copy (Accept keeps it, Decline deletes it). `LiveFileBackup` fails closed: entry probes use `lstat` so a final symlink is never followed, the snapshot creates exclusively (`COPYFILE_EXCL`, `COPYFILE_NOFOLLOW` on the copy fallback) and never deletes a peer's copy, and restore replaces atomically or moves into place.
- **Ledger serialization**: `live_reviews` (path primary key, optional `backup_path`, `created_at`, `resolution`, `resolved_at`) records live reviews, and `StagedFilesStore` runs write-start and resolution as serialized critical sections — the ledger read, rollback snapshot, row claim, and the caller's live write cannot interleave with a peer, and a decision claims the pending row before any filesystem mutation. Start outcomes are `started`/`joined`/`refused`/`unreadable`/`writeFailed`; an unreadable ledger or refused snapshot fails the write closed.
- **REST & WS**: `POST /files/review-status` answers a batch of 1–200 trimmed, non-empty paths with `{stagedStates, liveStates}`, echoing every requested path and defaulting missing rows to `"unknown"`; it reads the ledger only and fails non-2xx on a store error (absence is a definitive answer, while a failed read must not strip a pending card's controls). `POST /files/live-accept` keeps the live bytes and clears the copy; `POST /files/live-decline` restores the copy (or deletes a new-file review) and consumes it; both refuse `all: true`, re-enforce `FilesAccessGuard` on the live and rollback paths, and broadcast a detached `live_resolved` frame carrying the terminal `state`. Staged resolutions broadcast `file_accepted`/`file_discarded`; a live write that supersedes a staged review broadcasts `file_superseded` from the serving process (direct-core writers stay silent).
- **Dashboard**: one diff card serves chat and the single-column Staged Changes drawer; review cards collapse by default behind a chevron (chat setting "File Write Cards", default collapsed), settle their state from `review-status` hydration, and only the newest pending write per file owns Accept/Discard — older cards read "A newer write owns this file's review." The status pill renders the durable review state, never the write-time envelope.
- **Reserved namespace**: `.rune_`/`.rune_backup_` siblings are reserved review artifacts (case-folded guards on tool and route paths) and are never valid write targets; artifact removals only ever delete regular files.

---

## INTEGRATIONS

### Shipped

**Email**: IMAP search/read via `BODY.PEEK`, attachment staging, approval-gated send, with deterministic redaction of credential-bearing mail at the agent-visible boundary. **Apple Messages**: snapshot-copy search/read plus gated send. **Browser/web**: `web.search`, `web.fetch` (supervised per-hop egress), `browser.navigate` + `act` (supervised entry plus per-hop egress), `api.request` (surrogate-aware headers supervised by the mandatory `OutboundEgressSupervisor`, §15). **Desktop**: `desktop.screenshot` plus gated `desktop.action` (typed URLs supervised per batch, §15), off by default behind tool-state toggle. **Media**: `media.arr` gated plus `media.arr.read`. **Files & documents**: direct reads plus grep/glob/list via `FilesAccessGuard`, and reviewable writes (`files.write`) backed by the write-path posture precedence and the staged/live review ledgers plus the first-wins rollback copy (§16). **Local document index**: opt-in FTS5 plus vectors feeding `memories.recall`. **Goals/ideas/fan-out**: durable goals with proactive surfacing, an opt-in ideas engine, and opt-in multi-agent fan-out with per-worker/whole-run cancellation, live-broadcast swarm rows, and worker sessions that nest under their origin chat in history. **Calendar**: `calendar.search` read-only plus `calendar.create`/`calendar.update`/`calendar.delete` approval-gated, backed by the calendar EventKit gateway. **Reminders**: `reminders.search` read-only plus `reminders.create`/`reminders.update`/`reminders.delete` approval-gated, backed by the reminders EventKit gateway. **Declarative policy**: `~/.runeweaver/policy.toml` with Settings → Access as its dashboard home, a verify-only CLI check, and the REST settings routes (§15).

### Planned

Apple Mail native, HomeKit/Home Assistant control, Discord, GitHub.

---

## SECURITY MODEL

1. **Read by default, write with permission**.
2. **Least privilege**.
3. **Sandbox before trust**.
4. **No secrets in prompts**.
5. **Audit trail** locally with timestamps and inputs.
6. **Defense in depth for external content**: declaration-driven untrusted labeling, deterministic credential filtering, single-sourced SSRF egress, and surrogate credential references.
7. **Declarative deny-by-default egress over network (including the manual-only local_exemptions set) plus credentials**: `~/.runeweaver/policy.toml` owns `[network]` plus `[credentials.*]` and is verified by two formal invariants at the storage boundary — **credential confinement** plus **rule-shadow prevention** — plus local-exemption safety, then enforced at a single mandatory choke-point (`OutboundEgressSupervisor`) for `api.request`, `web.fetch`, `browser.navigate`/`browser.act`, `bash.exec`, and `desktop.action`; unverifiable policy fails closed at boot, and supervisor denial is evaluated before Keychain or DNS side effects.

Sandbox paths under `~/.runeweaver/` for config, `policy.toml`, `auth-sessions.json` (digest-only session state for sliding browser sessions), `index.db`, `memory/episodes.db`, `memory/vectors/`, logs, plugins, voice models. The policy file itself is additionally denied to sandboxed subprocesses via the Seatbelt profile.

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
plan_timeout_seconds = 0  # 0 = unlimited
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

Every section is additive with defaults on absent keys, so existing `config.toml` files load untouched. Full sample retains `[engine]`, `[auth]`, `[llm]`, `[voice]`, `[containers]`, `[files]`, `[browser]`, `[desktop]`, `[email]`, `[home]`, `[media.*]`, `[scheduler]`, and `[plugins]` as previously documented. All of these sections round-trip through `Config`/`ConfigTOML`/`Config+Serialization`/`Config+Validation`. `[containers]` carries `memory_mb` (default `512`, `256`–`8192`), `max_concurrent` (default `5`, `1`–`32`), and `ttl_minutes` (default `60`, `5`–`1440`); container images are pinned in code with no config key, and legacy `[sandbox]` keys are ignored on load with a logged note and shed on resave. Within `[files]`, `write_mode` (`"model"` default | `"staged"` | `"live"`) is the single authority on whether `files.write` honors the model's per-call `mode` or forces one, and `[[files.write_paths]]` entries (path plus posture, surfaced as `write_path_rules` on the settings routes) override the global mode per path with the longest matching rule winning; both apply live without a restart.

**Verified-pulse bounds are fixed in code, not config keys.** The subsystems behind the shared contracts carry their bounds as constants so no config edit can silently relax a verifier; each applies live with no restart.

- **Health (pulse)**: `HealthSnapshotValue.maxTipLength = 128` (a tip or hash longer than this is rejected to nil, never truncated — truncating a digest changes its identity), `maxDegradedReasons = 8`, `maxReasonLength = 160`. The served `status` vocabulary is closed (`green`/`yellow`/`red`); an unknown `probeVerdict` degrades to nil instead of failing the probe.
- **Watchdog (brake)**: `BehaviorWatchdog.gestationSeconds = 14 * 24 * 60 * 60` (silent until the baseline is armed), `trailingWindowSeconds = 3600`, `retainedMinuteBuckets = 120`, `rateMultiplier = 4` over the baseline hourly average with `rateFloor = 10`, `denialThreshold = 3` per trailing hour, `offHoursStartHour = 0` through `offHoursEndHour = 5` (local), `maxTrackedSessions = 500`, `maxPendingPerSession = 20`, `maxImportedBaselineDays = 28`; baselines persist counts-only at `~/.runeweaver/behavior/baselines.json` (0600, atomic).
- **Cache**: `SemanticAnswerCache.similarityThreshold = 0.92`, `timeToLive = 24 * 60 * 60`, `maxEntries = 500` (oldest evict first), `maxAnswerChars = 2000` (a longer answer is refused, never truncated, so a hit always replays complete text).
- **Probes**: `ProbeReport.maxProbes = 12`, `totalTimeoutSeconds = 30`, `perProbeTimeoutSeconds = 5`; fail-closed verifiers are `traversal`, `symlink-escape`, and `replay` (a boot failure aborts serve); degrading verifiers are `firewall-redaction`, `ledger-integrity`, `zero-socket`, and `vault-round-trip`. The nightly cadence rides its own loop at `24 * 60 * 60` seconds.
- **Sends**: `ScheduledSendBounds.maxRecipientChars = 254`, `maxSubjectChars = 998`, `maxTextChars = 10000`, `maxHtmlBytes = 1_048_576`, `dueGraceSeconds = 5 * 60` (past due settles `failed`, never catch-up stacked); `SchedulerStore.maxPendingSends = 200`; fire times are minute-aligned within `ScheduledSendTimeValidation.minimumLeadSeconds = 5 * 60` and `maximumHorizonSeconds = 365 * 24 * 60 * 60`.

**Sovereign sidecars**: `~/.runeweaver/memory/ledger.sovereign.jsonl` (hash-chained copy, refused above `SovereignLedger.maxSovereignCopyBytes = 50 * 1024 * 1024`), `~/.runeweaver/sovereign-checkpoint.json` (Enclave-signed vote, unarbitrable past `maxCheckpointAge = 36 * 60 * 60`), and the signing key at `~/.runeweaver/sovereign-signing.key` (`EnclaveHMACSigner.keyLength = 32`, created exclusively and 0600).

**Separate declarative policy file (`~/.runeweaver/policy.toml`, not part of `config.toml`)**: top-level `version`; `[network]` with `mode` (`allowlist_only` | `unrestricted`), `allowed_domains`, `blocked_domains`, `local_exemptions` (owner-asserted private-address trust); `[credentials."<key>"]` with `allowed_hosts` (exact hosts plus a single leading `*.` subdomain edge), `allowed_methods` (`GET`/`POST`/`PUT`/`PATCH`/`DELETE`/`HEAD`/`OPTIONS`, empty means Any), `allowed_path_prefixes` (must start with `/`, empty means Any). Legacy `[filesystem]` plus `[tools.*]` tables are ignored on load and never written back; a legacy `deny_by_default` mode parses as `allowlist_only`. TOML arrays are single-line per element-list convention (enforced by the parser). The file owns network (including the manual-only `local_exemptions` set) plus credentials and is held by `PolicyStore`, edited in Settings → Access (the Network and Credentials rail sections: structured editors plus read-only local-exemption display with Re-check plus list plus modal with shared settings-footer Save, live apply with no restart, no in-app raw editor) and verified on demand via `rune-weaver policy verify`, and only the manual settings paths may write `local_exemptions` — tools never write it at runtime.

---

## SHARED CONTRACTS

Six cross-cutting contracts govern the verified-pulse subsystems. They are stated once here and implemented in the components named in each entry.

- **HEALTH**: status is green plus yellow plus red only. Green means all verifiers pass, yellow means degraded with details behind disclosure, red means fail-closed with inbox item. The dashboard clears red only on a fresh passing snapshot, never on timer expiry.
- **SOVEREIGN**: primary ledger plus sovereign copy plus Enclave-signed checkpoint vote. A mismatch parks with red; there is no silent repair; a revert needs explicit approval.
- **BRAKE**: the watchdog counts only with no bodies — never arguments, prompts, or model output. The brake parks all running turns plus clears steering plus files an inbox item; it never auto-remediates plus never approves; resume needs explicit user action.
- **CACHE**: the semantic cache stores pure answers only. Tool turns plus approvals plus sends never store plus never hit. Invalidation happens on memory write plus goal change plus policy change.
- **PROBE**: probes run at boot plus on policy write plus on nightly tick plus on-demand, never per tool call. Failures write a red snapshot with an inbox item.
- **SEND**: a scheduled send stores immutable bytes plus recipient plus fire time at the approval moment. The fire worker sends the stored bytes with re-validation plus no LLM regeneration. Exactly-once claim via the queued to sending transition. Cancel plus edit need a fresh approval.

Two governing rules ride alongside them. **Boot plus live truth**: these docs carry no boot state — every subsystem reports live state, a file save applies live with no restart plus no watcher, and "the dashboard clears red only on a fresh passing snapshot" stays the governing rule wherever the pulse appears. **Fail-closed plus bounds**: a refused or unverifiable input stays refused — denied stays denied when authenticated — and every list, digest, payload, and timer in these subsystems is bounded by the constants transcribed in CONFIGURATION.

---

## DECISIONS & CONSTRAINTS

### Key Decisions

1. **Swift over Python for core**.
2. **Actor model for concurrency**.
3. **WebSocket for client-server & sliding durable sessions**.
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
33. **Multi-agent fan-out is opt-in with read-only workers**: concurrent worker turns get fresh sessions and a read-only tool subset; merge is deterministic overlap flagging first, then one background reviewer pass that fails open to the raw concatenation, and workers never exceed their permission gate. A swarm is cooperatively cancellable — one worker or the whole run — through row-keyed cancel from the Runs surface; the same row-keyed `POST /runs/:id/cancel` cooperatively cancels any other running row via `ActiveTurnTracker` cancel plus `steeringQueue.clear` for the row's session, settling the row to `cancelled` with a hub broadcast, so cancellation is not fan-out-only.
34. **Grouped navigation, click-only menus**: Dashboard, Chat, and Approvals stand alone (with Dashboard as the default landing surface) while Work groups Goals/Schedules/Runs and Memory groups Search and Memory plus Index Status; navigation groups tab-state (no router); dropdowns are click/keyboard-only — hover-open is deliberately excluded.
35. **Declarative deny-by-default egress with mandatory supervision**: `~/.runeweaver/policy.toml` owns network (including the manual-only `local_exemptions` set) plus credentials and is held by a verifying `PolicyStore` actor (two formal invariants — credential confinement plus rule-shadow prevention — plus local-exemption safety at the storage boundary; server-owned serialization with round-trip proof; atomic file-first writes; factory-safe defaults on failure; `snapshot()` throws when unverified); `OutboundEgressSupervisor` is the multi-consumer choke-point for `api.request`, `web.fetch`, `browser.navigate`/`browser.act`, `bash.exec`, and `desktop.action` egress (network gate with session plus one-shot grants → binding gate → SSRF over auto service origins union `local_exemptions` → JIT secret injection → response sweep), mandatory at every production entry point with per-tool session threading, sharing one `PolicyStore` per process with the settings routes so HTTP policy writes and re-check applies land live with no restart plus no watcher; the agent-writable path never widens the SSRF set while owner-configured `local_exemptions` explicitly does. Each allowed verdict carries a **dial pin** (the numeric addresses the SSRF gate proved plus the original host identity), and the transport dials that pin with the original `Host` header and TLS server name instead of resolving the hostname again — so the pre-dial gate order also closes the connect-time DNS-rebinding race on the initial URL and every redirect hop, and a missing pin fails closed.
36. **Single-gate enablement for tool-invoked capabilities**: a capability that runs only when its tool is invoked (desktop, fan-out) has exactly one enablement switch — the persisted tool-state toggle — and its config section carries only behavior knobs. It ships disabled and stays visible in `GET /tools`; removing a redundant config `enabled` gate is a correctness fix, not a convenience. Subsystems with background entry points (scheduler, goals, ideas, index) keep a config `enabled` because work can start without a tool call.
37. **Fan-out timeout is opt-out, bounded by cancellation**: `worker_timeout_seconds` defaults to 0 (unlimited) because local inference can exceed any short budget, and a default timer kills workers mid-turn; owners may set a positive budget (clamped 1–86400s). The escape hatch for an unbounded worker is cooperative cancellation, never a forced kill.
38. **Session origin metadata is durable and honest**: every session stores its turn origin `source` (e.g. `dashboard`, `websocket`, `api`, `scheduler`, `goal`, `fanout_worker`) plus an optional caller-supplied `title`; fan-out worker sessions additionally store `parent_session_id` linking them to the chat that spawned the swarm. `UserInput` carries `title`/`parentSessionID`; `Orchestrator.process` fills them through its single `ensureSession` call with nil-never-clears semantics and `overwrite: true` on goal-tagged turns — the chat history can therefore classify and nest sessions without joining run history.
39. **No silent run writes**: every `run_logs` row write broadcasts `run_started`/`run_completed` on the WSHub. Fan-out rows ride the dedicated `FanOutRunLogAdapter` (`RunLogStore` + `WSHub`); the prior store-only `FanOutRunLogging` conformance is deleted so exactly one broadcast path exists and no row kind can write silently.
40. **Grouped fan-out history with live refresh**: the dashboard nests worker sessions under their parent chat behind a collapsed, ephemeral disclosure (parent keeps its chat icon and gains a chevron plus child-count chip; children get the fan-out icon and indentation; orphans surface top-level; deletion never cascades), and revalidates history on coalesced run frames (750 ms), Chat-tab activation, document visibility regain, and socket reopen — no `sessions_changed` frame is introduced.
41. **File writes are reviewable and ledger-backed**: `files.write` stages into a `.rune_<name>` sibling by default (accept promotes, discard deletes, a later live write supersedes); live writes snapshot one first-wins `.rune_backup_<name>` rollback copy that joining writes never touch and that a decision removes; a new-file live series owns no copy. Resolutions are durable terminal states (`staged_files.resolution`, `live_reviews`), so a reloaded card can never resurrect a settled review, and clients hydrate through the batch `POST /files/review-status` query. Only the newest pending write per file owns the review controls.
42. **`[files] write_mode` is the single write-posture authority**: `model` (default) honors the per-call `mode` argument; `staged`/`live` force the posture, accept and ignore a stale per-call argument, name the override in the envelope, and drop `mode` from the advertised schema while forced. The write-mode selector, the write-path rules table, and the files read-guard editor (allow roots, deny patterns, approval-on-deny) are edited together in Settings → Access → Files — the read-guard editor was re-homed there from Settings → Security so the whole files trust surface (write posture plus read boundary) consolidates in one Access section.
43. **Review artifacts are a reserved, fail-closed namespace**: `.rune_`/`.rune_backup_` siblings are never valid write targets (case-folded); snapshots probe with `lstat` and never follow a final symlink, create exclusively, and never delete a peer's copy; review start and resolution serialize through `StagedFilesStore` so a decision cannot consume a copy a concurrent write is joining.
44. **The system pulse is a closed, verified green/yellow/red verdict**: `SystemHealthSnapshot` fuses subsystem probes, the live policy posture read fresh on every snapshot, and sovereign ceremonies into one status; absence of a recorded failure is not a failure — verifiers constrain the pulse only once they report — and red wins over yellow. The verdict rides `GET /health` with owner-private tips and the `health_updated` push frame carrying the operational signal only, published solely on deep change, so steady-state polling never re-fans an identical pulse and the dashboard clears red only on a fresh passing snapshot, never on timer expiry.
45. **The sovereign ledger proves history without rewriting it**: the primary episode store stays the source of truth; a hash-chained sovereign copy plus an Enclave-signed checkpoint corroborate it, with strict decoding (unknown fields, discontinuities, chain or HMAC breaks) throwing rather than concluding. Ledger growth extends the copy and re-attests as the normal outcome, a broken prefix parks red with nothing rewritten, a stale checkpoint fails closed, and re-attestation is an explicit act — a restored copy is corroborated by a verified vote, never a silent repair.
46. **The behavior brake counts, parks, and waits**: the watchdog retains counts only — tool name, session, outcome — never content; a fired rule parks every running turn through the existing cooperative cancel contract, clears their steering, and files one numbers-only card into the approvals inbox, idempotent while engaged. It never auto-remediates and never approves, a "keep paused" decision leaves the park untouched, and Resume — the only clear path — resets the trailing counters so the observed spike cannot immediately re-fire. Silent through gestation, because an unarmed baseline has nothing to compare against.
47. **The semantic answer cache is narrow by construction**: only pure Q&A turns store and hit; tool turns, approvals, sends, and voice prompts are excluded at the turn boundary, so "never store" implies "never hit". State is in-memory and starts empty at every boot; one full-clear invalidation primitive is the single route memory writes, goal changes, and policy changes share, so no partial invalidation path can replay pre-write text.
48. **Scheduled sends are byte-immutable and exactly-once**: approval stores the exact bytes, recipient, and fire time; the fire worker replays the stored bytes through the owning tool with re-validation and no LLM regeneration, claiming due rows exactly once through the queued-to-sending transition. Cancel plus edit need fresh approval because the stored payload is the approved artifact; past-due sends settle `failed` with a stored reason instead of stacking catch-up fires, and every fire and skip is audited as a run row.
49. **Durable trust is an access rule, not a grant**: one rule = (toolName, AccessScope, AccessAction, duration), with scopes `toolWide`, `exactTarget`, `recipientSet`, `domain(host:subdomains:)`, `pathPrefix`, and `glob`, and durable tiers `fiveMinutes`/`oneHour`/`oneDay`/`forever` (nil = standing, never expires). Spelling is owned per shape by the `AccessScope` canonicalizers and `AccessScope.matches(toolName:argumentsJSON:)` is the single scope matcher, so a malformed scope is rejected at creation and never matches at evaluation. `exactTarget` carries the legacy grant target byte-for-byte, so a migrated rule keeps covering exactly the call the owner approved; task and session trust stays ephemeral (`EphemeralGrant`), dying on its lifecycle boundary and never persisting as a durable row.
50. **Deny outranks every allow**: a durable deny rule is evaluated before any grant coverage, never expires, and is removed only by explicit revoke; no allow rule overrides, shortens, or evicts a deny for the same scope, and widening never promotes a deny. Only an explicit owner decision (approved=false plus forever) or `PermissionGate.denyRule(scope:toolName:reason:)` mints one.
51. **The Inbox groups by session and decides per card**: pending approvals group under sticky session headers titled from `GET /sessions` (unattributed under "Unattributed"), groups order by maximum card severity and cards by severity then filing time, and no card hides behind a collapsed group — no group-level or bulk approve exists anywhere; every card carries its own Allow and Deny with the full duration picker and scope editor, the dashboard quick actions stay one-shot ("Approve once" / "Deny") with an "Open in Inbox" link, and the brake card is the sole exception with its dedicated Resume plus Keep-paused branch.
52. **One decision contract, placed surfaces**: `POST /approvals/:id/decide {approved, duration, scope}` is the only decision path — the chat inline banner, the Inbox, the dashboard quick actions, and WebSocket triage all send it. The Inbox decides pending requests only while standing rules live in Settings → Access (with the declarative policy editors as the policy's UI home in its Network and Credentials sections); the menu bar and native notifications stay signal-only — an "Attention required (n)" row and an informational tool-plus-severity notification route to the Inbox and never decide.
53. **The CLI collapses to ops**: `rune-weaver` carries only auth, policy verify, serve, and status. The chat loop, the goals command, and every approval-deciding surface are gone; the service is the only turn runner and the dashboard is the only interactive surface, so each shipped behavior lives in exactly one place.

### Constraints

- Apple Silicon required for MLX; Intel via llama.cpp/cloud only.
- Single-owner, fail-closed binding and host enforcement, auth-before-exposure, ATS local-networking only.
- Owner sessions: sliding 24h idle window (`rw_session` `Max-Age` 86400, refreshed at most once per 5 minutes of activity, no absolute cap); `maxActiveSessions` 100 with least-recently-seen eviction; session state keyed by SHA-256 digest and persisted digest-only in `~/.runeweaver/auth-sessions.json` (0600, atomic); rotation clears all sessions; unreadable, loose, corrupt, or unknown-version stores fail closed to no sessions.
- Local-first; opt-in indexing; opt-in desktop with OS permissions; Messages send always gated.
- Default-ON hardening; no live secrets in context; fail-closed transport.
- Declarative egress policy: network (including the manual-only `local_exemptions` set) plus credentials with deny-by-default allowlist posture; `mode` is `allowlist_only` | `unrestricted` (`deny_by_default` parses as `allowlist_only` on load); credentials bound to `allowed_hosts`/`allowed_methods`/`allowed_path_prefixes` under credential confinement plus rule-shadow prevention plus local-exemption safety; `local_exemptions` carries well-formed exact, `host:port`, or single leading `*.` entries with metadata, link-local, and embedded translations never-exempt; legacy `[filesystem]` plus `[tools.*]` ignored on load and never persisted; the agent-writable path never widens the SSRF set while owner-configured `local_exemptions` explicitly does; unverifiable `policy.toml` fails closed (CLI exits nonzero, serve refuses boot) — never permissive defaults.
- Bounds: `memories.recall` limit 1–50 default 5; auto-recall bounded by `recall_auto_limit`, `recall_threshold`, `recall_max_chars`, `recall_per_hit_chars`; doc pool bounded by `recall_doc_pool_multiplier` (1–8); episodic weight 0–1; `messages.search` 1–50 default 10; `messages.read` 1–100 default 20; empty text rejected; AppleScript rejects null bytes.
- Goals bounds: `step_interval_minutes` 5–20160; `max_active_goals` 1–50; `max_steps_per_goal` 1–24; `max_triggers_per_goal` 0–32; `plan_timeout_seconds` default 0 (unlimited), bounds 0–86400.
- Fan-out bounds: `max_workers` 1–8 default 2; `worker_timeout_seconds` 0=unlimited, 1–86400 otherwise; `full_tools` default false. Cancellation is cooperative (no hard kill): `fanout`/`fanout_worker` rows cancel through the engine registry, and every other running row cancels via `ActiveTurnTracker` cancel plus `steeringQueue.clear` for the row's session, settling to `cancelled` with a hub broadcast.
- File-write bounds: `write_mode` ∈ {`model`, `staged`, `live`} default `model`; write-path rules (`[[files.write_paths]]`, patched wholesale as `write_path_rules` through the settings routes) carry at most 50 entries, each path at most 1024 chars, with the posture from the closed set {`live`, `stage`, `ask`, `deny`} — the longest matching rule wins and ties keep declaration order; a forced posture overrides the per-call `mode`; `.rune_`/`.rune_backup_` are reserved review artifacts and never valid write targets; `POST /files/review-status` accepts 1–200 trimmed non-empty paths, answers `"unknown"` for absent rows, and fails non-2xx on a ledger read error; review artifacts must be regular files — directories and symlinks are refused, and snapshot/copy fallbacks never follow a final symlink.
- Access-rule shapes: `GET /approvals/rules` lists live rules newest-first with allows and denies together; `POST /approvals/rules` mints a standing allow (tier `fiveMinutes`/`oneHour`/`oneDay`/`forever`, or absent for standing) or a deny (always standing, tier ignored); `DELETE /approvals/rules/:id` revokes future-only — past allowed calls stay in history; `PATCH /approvals/rules/:id` re-arms an allow rule to a new durable tier in place; `POST /approvals/rules/:id/widen` widens an allow rule to tool-wide and never a deny; every durable write broadcasts `access_rules_changed`. An unknown id is 404, a non-widenable live rule is 409, a non-re-armable tier is 400, and a `messages.send` rule must name a recipient set or a canonical handle. Rule scopes carry the `AccessScope` bounds: recipient sets at most 50 members, hosts at most 253 chars, path prefixes at most 1024 chars, globs at most 256 chars.
- Ideas bound: `max_per_cycle` 1–10 default 3.
- Session origin metadata: `parent_session_id` is a best-effort additive column (legacy rows decode as unlinked); `source`/`title`/`parent_session_id` fills never overwrite stored values without `overwrite: true`.
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