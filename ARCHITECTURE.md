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
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │ Discord  │ │  GitHub  │ │ Messages │ │ Calendar │          │
│  │(planned) │ │(planned) │ │(shipped: │ │(planned) │          │
│  │          │ │          │ │search +  │ │          │          │
│  │          │ │          │ │read +    │ │          │          │
│  │          │ │          │ │gated send│ │          │          │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘          │
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌────────────────────┐              │
│  │   Home   │ │Apple Mail│ │ Desktop (vision +  │              │
│  │(planned) │ │(planned) │ │ gated control;     │              │
│  └──────────┘ └──────────┘ │ shipped, off by    │              │
│                            │ default)           │              │
│                            └────────────────────┘              │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Future: Custom Skills via plugin registry   │  │
│  └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

The Document Index is not a separate process: it is an actor-backed local store inside the core engine, sitting beside the other Support Services and feeding `memories.recall`. See Component Details §10.

Shipped tool set: Email IMAP/SMTP (`email.search`, `email.read`, `email.attachment`, `email.send`, `email.listMailboxes`, `email.move`), web + browser (`web.search`, `web.fetch`, `browser.navigate`, `browser.act`, `api.request`), files (`files.read`, `files.grep`, `files.glob`), memory (`memories.store` canonical with `remember_fact` alias, `memories.recall` canonical with `recall_memories` alias), Apple Messages (`messages.search` read-only, `messages.read` read-only, `messages.send` approval-gated with dry-run preview), media automation (`media.arr` approval-gated search/add/queue/status plus `media.arr.read` read-only search/queue/status over self-hosted Sonarr/Radarr), desktop perception and control (`desktop.screenshot` read-only plus `desktop.action` approval-gated over self-hosted macOS session; always registered but fail-closed — ships disabled and runs only when the persisted tool-state toggle enables it; `[desktop]` carries only capture knobs). Planned: Apple Mail native, HomeKit / Home Assistant control, Discord, GitHub, Calendar (config knobs and marketplace stubs only — no tool implementations).

### Engine-to-Service Shift

The core engine is shifting from a CLI-only tool to a local service that other UIs drive through one HTTP surface.

- **Vapor API layer**: A Vapor service fronts the core engine and exposes chat, health, tools, memory, approvals, runs, and scheduler operations as JSON routes. The dashboard and future clients call the engine through this layer; the CLI remains direct-core for v1 (`chat` and `scheduler run` link `RuneWeaverCore` directly via `CLIShared.makeToolBus` and `Orchestrator` instead of going through HTTP, so terminal use works with no service running). The service itself launches from the CLI binary via `rune-weaver serve`, which builds a `ServerContext` with `ServerContext.make(...)`, registers the shared plugin tools, configures a Vapor `Application` with `configureRuneWeaver(_:context:)`, and runs it.
- **CLI index wiring (shipped)**: The CLI chat loop inspects `config.index.enabled`. When enabled it resolves `config.index.databasePath(in: stateDir)` and passes `docIndexDBPath` into the memory engine, so terminal turns get the same indexed file, mail, and message candidates as the service without a running daemon.
- **WebSocket event hub & real-time streaming**: The service maintains a persistent WebSocket endpoint (`/ws`) managed by `WSHub`. Chat turns stream live text deltas, tool invocations, and tool outcomes, tagged with `sessionID` so frontend views multiplex over a single shared connection (`useSharedWebSocket`) without cross-session leakage. In-flight turns support mid-turn cancellation via WebSocket frame (`{"type": "cancel"}`) or REST (`POST /chat/cancel`), which aborts the underlying Swift task via `ActiveTurnTracker`.
- **Authoritative concurrent-turn cap**: `ActiveTurnTracker.maxConcurrentTurns = 3` bounds simultaneous chat turns across REST and WebSocket (a replacement turn for the same session supersedes its slot; a fresh session past the cap fails with an honest busy notice). Every `GET /health` probe advertises the cap in the `X-RuneWeaver-Max-Concurrent-Turns` header alongside the JSON body so the dashboard prefers the server value and only falls back to its mirrored constant for older engines. `GET /health` also carries the live SearXNG Start flight stage (nil when idle).
- **Durable SQLite persistence for scheduler & run history**: Scheduled jobs (`scheduler_jobs`) and execution audit logs (`run_logs`) persist in SQLite (`episodes.db`). The `config.toml` `[[scheduler.jobs]]` table is used solely as an initial bootstrap seed when the database has zero jobs. Runtime edits persist immediately to SQLite, and run states (`running` → `ok`/`error`/`cancelled`, plus `awaiting_approval` → `ok`/`error`/`denied` for approval-gated parked turns) are tracked live, with interrupted runs reconciled on restart. Every `run_logs` row carries a nullable `session_id` column (backfilled via migration for older databases) linking the turn to its owning chat or per-run scheduler session (fresh `UUID()` per execution) so parked approvals resume in the same session.
- **Static dashboard bundle**: The web dashboard ships as a static bundle served by the engine itself. It chats, browses memory, inspects run history, manages schedules, and surfaces the approvals inbox in a browser with no separate frontend host process. When owner auth is active the bundle is still served publicly and renders its own owner-token gate before any data request, so an unauthenticated visitor reaches the sign-in view instead of a dead end. The in-bundle auth gate strictly fails closed: if the initial health probe fails, rejects, or drops network connectivity, stored credentials are cleared and the gate defaults to `"required"` rather than failing open.
- **Document index surface**: The service exposes `GET /index/status` (counts, bytes, `index_as_of`, per-source enablement, last errors, last run, plus an additive `live` snapshot), `POST /index/run`, `POST /index/cancel`, `POST /index/prune`, and `POST /index/reset`, plus an `index` partial patch on `PUT /settings`. Live numbers ride the additive `live` snapshot on the status poll (`trigger`, `phase`/`stage`, `scanned`/`indexed`/`skipped`/`errors`, `rate` in docs/s, `elapsedMs`, `current`; null when idle so the live block unmounts with no post-run persistence). The dashboard owns a 2s in-run poll of `GET /index/status` while a run is in flight (paused when the tab is hidden, no idle polling); WebSocket `tool_progress` plus `run_started`/`run_completed` frames are poll-now wake-up triggers only, never the data carrier. The boot path (`ServerIndexBoot`) wires `config.index` into `DocIndexStore`, `IndexCoordinator`, `MemoryEngine`, and `ServerContext` for both `serve` and the menu-bar app.
- **Same trust boundary**: Every service-triggered write still flows through the permission gate with graduated trust, sandbox staging, and the local audit trail. The service layer adds transport; it does not bypass approvals.
- **Single-owner bearer auth & ephemeral browser sessions (shipped)**: Exactly one owner token guards the engine HTTP surface, whether it is launched through `rune-weaver serve` or the menu-bar app's embedded service. The token is a 256-bit URL-safe value minted by `rune-weaver auth token generate` and resolved at boot from `token_env`, then the Keychain account, then a `0600` `token_file`. It is verified in constant time, and failed non-loopback attempts throttle per client with `Retry-After`. Browser clients exchange the owner token via `POST /auth/session` for an ephemeral, actor-managed session token stored in an `HttpOnly`, `SameSite=Strict` `rw_session` cookie; the master bearer secret is never placed in cookies or browser storage by the app. Active browser sessions are tracked in-memory by `ServerAuth` (capped at 100 sessions), revoked server-side on `DELETE /auth/session`, and automatically flushed upon token rotation (`POST /auth/rotate`). The `Secure` cookie flag is proxy-aware (`request.url.scheme == "https"` or `X-Forwarded-Proto: https`). Middleware gates every data path — REST and the WebSocket upgrade — returning the same uniform `401`; only the static dashboard bundle and a minimal liveness shape are public. Rotation invalidates all live sessions so a leaked cookie dies with the old token.
- **Fail-closed binding (shipped)**: Loopback (`127.0.0.1`, `localhost`, `::1`) always serves. A non-loopback bind is accepted only when a token resolves (`ServerConfig.requireBindable`); otherwise boot is refused rather than silently downgraded to an unauthenticated LAN bind. WireGuard (or equivalent) remains the recommended transport off-LAN.
- **Service auto-fire plus per-process single-flight**: The service auto-fires scheduler cron and poll triggers in-process, sharing one lock with the manual run route so overlapping fires inside the service process skip with `409` instead of stacking. The CLI `scheduler run` foreground loop is a second auto-fire runner in a separate process with no shared state, so the same job name can still run concurrently via service plus CLI in v1 — run one auto-fire runner at a time.

---

## COMPONENT DETAILS

### 1. Core Engine (Swift)

The core engine is a Swift package that runs as a persistent process. It owns:

- **Orchestration**: Receives user input (text or voice transcription), routes it through the LLM, executes tool calls, and returns responses.
  - **Dynamic System Prompt Composition**: `SystemPromptComposer` snapshots the live tool registry (`ToolBus.availableTools()`) at session start and generates a deterministic system prompt including canonical tool names, descriptions, input schemas, permission levels, tool-use policies, and memory guidance. Canonical memory names (`memories.store`, `memories.recall`) are advertised; legacy aliases are never advertised.
  - **Narration Fallback for Local LLMs**: When local or quantized models output text narration instead of structured function calling, `OrchestratorToolLoop` extracts and executes read-only tool calls, while approval-gated narrations are filed through the approval queue and left unexecuted until decided.
  - **In-Flight Turn Cancellation**: `ActiveTurnTracker` tracks running turn tasks across both WebSocket and REST routes, allowing callers to cleanly abort long-running turns.
- **Conversation Manager**: Maintains session state, conversation history, and context windows across durable SQLite tables (`sessions`, `messages`) and hydrates missing cache entries from disk.
- **LLM Router**: Abstracts LLM providers. Selects the active provider, handles fallback chains, manages API keys and connection pooling.

Key patterns:
- **Swift Actors** for concurrency isolation between components
- **Protocol-oriented design** so each subsystem (LLM, tools, memory) is defined by protocols, not concrete types
- **Structured concurrency (`AsyncStream`/`AsyncSequence`)** for streaming LLM responses

### 2. LLM Provider Abstraction

```
Protocol: LLMProvider
  ├── func chat(messages: [Message], tools: [Tool]) -> AsyncStream<LLMResponse>
  ├── func embeddings(text: [String]) -> [[Float]]
  └── var modelInfo: ModelInfo

Implementations:
  ├── MLXProvider               // Local models via MLX (Apple Silicon)
  ├── LlamaCppProvider          // Local models via llama.cpp server
  └── OpenAICompatibleProvider  // Cloud (OpenAI, OpenRouter) and any custom OpenAI-compatible endpoint

Routing and configuration:
  ├── LLMRouter            // Priority-ordered providers with fallback on failure
  ├── ProviderConfig       // One [llm.providers.<name>] entry (RuneWeaverCore)
  ├── ProviderKind         // Backend selector: mlx / llamacpp / openai-compatible
  └── LLMProviderFactory   // Builds providers from ProviderConfig plus resolved API keys
```

The LLM Router maintains a priority-ordered list of providers and falls through on failure. Users configure providers via the dashboard or config file.

Provider config supports `api_style` (`chat-completions` default, `responses` opt-in). The provider HTTP client sends `User-Agent: rune-weaver/<version>` on every request and `x-opencode-session` when a chat session ID is set. For local self-hosted endpoints configured over cleartext HTTP with multi-label LAN domain names, `LocalNetworking` transparently resolves hostnames to private IPs (RFC 1918 / RFC 4193) and attaches the original `Host` header to comply with Apple App Transport Security (`NSAllowsLocalNetworking`) without hardcoding exception domains.

### 3. Tool Plugin System

Tools are the agent's hands — they do things in the world. Each tool is a self-contained module that declares:
- **Name and description** (for the LLM to understand when to use it)
- **Input schema** (JSON Schema for function calling)
- **Permission level** (read-only, requires-approval, trusted)
- **Handler function** (the actual implementation)

**Plugin Protocol (Swift)**:
```swift
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONSchema { get }
    var permissionLevel: PermissionLevel { get }
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput
}
```

**Alias compatibility (shipped)**: `ToolBus` carries an alias table (`aliases: [String: String]`) mutated only via `ToolBus.registerAlias(from:to:)`. `executeTool` and `toolNames` resolve aliases transparently to canonical implementations. `unregister` clears aliases in both directions so a removed tool cannot be reached by its old name. Canonical memory tools register their aliases once via `MemoryTools.registerMemoryAliases`. Unknown aliases fail closed with an unknown-tool error envelope carrying the `callID`.

**Python Plugin Bridge**: Python tools run out-of-process via standard JSON-RPC 2.0 over stdin/stdout (`SubprocessToolBridge`) — PythonKit is explicitly not used, keeping crash isolation, memory safety, and macOS Hardened Runtime compliance. The Python tool runs in a sandboxed subprocess and communicates via JSON-RPC over stdin/stdout.

**Shipped built-in web and browser tools** (the shared five-tool set on `ToolBus`, same in CLI and serve, under one `[browser]` policy):

- `web.search` (`readOnly`): static search over self-hosted SearXNG JSON. The returned hit count is the smaller of the caller limit and `[browser] max_results`, so the model cannot fan out unbounded context.
- `web.fetch` (`readOnly`): bounded single-page read with per-hop allowlist checks, SSRF guard, redirect bound, byte cap, and a typed `ok` / `auth_required` / `unsupported` envelope.
- `browser.navigate` (`readOnly`): interactive page open over the isolated Playwright bridge in a fresh context with no persistent profile; returns distilled text plus snapshot refs.
- `browser.act` (`requiresApproval`): one validated action against a `browser.navigate` snapshot ref; every call parks in the approvals inbox; dry runs return a would-act preview.
- `api.request` (`requiresApproval`): constrained HTTP (GET, POST, PUT, DELETE) replacing shell curl, with allowlisted headers, body/response caps, per-hop SSRF checks, manifest-only file pulls, and dry-run previews.
- `media.arr` (`requiresApproval`): Sonarr (TV) plus Radarr (movies) search, add, queue, and status against self-hosted instances; every call parks in the approvals inbox and dry runs preview without dialing (reads stay local, adds preview through the client).
- `media.arr.read` (`readOnly`): approval-free search, queue, and status over the same client path; an `add` routed here fails closed with guidance to use the gated `media.arr` tool instead.

**Memory tools (shipped, canonical)**: `memories.store` (`trusted`, alias `remember_fact`) stores one durable fact; `memories.recall` (`trusted`, alias `recall_memories`) searches past turns, stored facts, and indexed documents (files, mail, messages) on one calibrated scale. Descriptions tell the model that recall covers indexed documents. Trusted status follows the owner memory-write ruling; graduated trust still applies.

**Apple Messages tools (shipped)**: native macOS suite on the same `ToolBus`, registered through `BuiltinToolPlugins` so CLI and serve cannot drift.
- `messages.search` (`readOnly`): keyword search over historical SMS/iMessage with optional handle/phone/email filter and date limit.
- `messages.read` (`readOnly`): sequential history for one handle or chat identifier with limit 1–100, default 20.
- `messages.send` (`requiresApproval`, never `trusted`): sends via `ProductionMessagesGateway` through `BoundedProcessRunner` AppleScript with escaping against string injection (backslash, double-quote, newline escaped; embedded null bytes rejected). Honours `context.dryRun` with a would-send preview and no dispatch. The `MessagesGateway` protocol plus `StubMessagesGateway` keep unit tests hermetic.

**Desktop perception and gated control (shipped, off by default)**: native macOS session tools on the same `ToolBus`, registered through `DesktopTools.makeTools` and `BuiltinToolPlugins.makeAllTools` / `registerAll` so CLI, menu-bar app, and serve cannot drift. `desktop.screenshot` (`readOnly`) captures a display or a named app window and returns an in-memory downscaled JPEG plus coordinate metadata (`scaleX`/`scaleY`, original/scaled dimensions, content hash, optional window list). `desktop.action` (`requiresApproval`) executes a bounded batch of mouse, keyboard, and app-switch actions with downscaled-to-native coordinate translation. Both tools always register — visible in `GET /tools` instead of shape-shifting with config — but they ship disabled, and enablement flows solely through the persisted tool-state toggle: a tool stays disabled until an operator enables it (dashboard Tools tab / tool-state API), which is the sole authority for enablement. The `[desktop]` section carries only capture knobs (dimensions, quality, blocklist) and never gates enablement. Captures follow the same vision-gate contract as browser screenshots: bounded, held in memory for the turn only (never written to disk), with only the content hash plus dimensions/scales retained for durable history (`strippedForPersistence` / `redactedForPersistence`). Control follows the same trust boundary as every other write: every batch parks in the approvals inbox and dispatches only after approval, with `blocked_apps` pre-checks, a fail-safe corner abort, and an operator emergency stop.

**SearXNG lifecycle**: `SearXNGEnsurer.shared` keeps the local engine warm — ensured on `serve` boot and first search, single-flight in-process. The runtime is the Apple Container CLI only (`container`; Docker is unsupported) with loopback-only publish, a per-install settings file carrying a random secret (directory `0700`, file `0600`), and fail-closed guidance when down. The container stays running after quit by design; `rune-weaver status` reports `reachable`/`unreachable`.

**Navigate/act isolation**: navigate and act share one Playwright gateway but never share state. Each call opens a fresh isolated context with no persistent profile, no stored credentials, and no cross-task storage, then closes it before returning.

**Screenshot and vision gate**: `browser.navigate` carries an opt-in `includeScreenshot` flag (default false). Captures are bounded, held in memory for the turn only (never written to disk); only a content hash persists in the audit trail. The gate is model-aware: `VisionGate` strips image payloads for text-only models, `LLMRouter` hides `includeScreenshot` from tool schemas sent to text-only providers, and `SystemPromptComposer` advertises the opt-in only when `supportsVision` is true. `desktop.screenshot` reuses the same gate: the live turn keeps the data URL in memory while persisted run logs, message history, and episodic records keep the stripped envelope.

**Search health surfaces**: search health shows in the `status` command, the dashboard Profile menu (TopNav), and the Settings Web pane — all fed by the same probe plus the live Start-flight snapshot, with tri-state Reachable/Stopped/Unknown pills (plus a Starting pill while in flight).

### 4. Memory Engine (shipped)

Three tiers of memory, each backed by different storage:

| Tier | What | Storage | Lifecycle |
|------|------|---------|-----------|
| **Working Memory** | Current conversation context | In-memory + SQLite sessions (Core Engine) | Session-scoped, oldest turns fold into a rolling summary when over budget |
| **Episodic Memory** | Past conversation turns as cleaned per-turn rows | SQLite + FTS5 | Permanent, mirrored clean every turn via `mirrorTurn` for resume; auto-compacts sessions older than 30 days when records exceed `maxEpisodicCount` (10,000) |
| **Semantic Memory** | Facts, preferences, user profile | JSON vector store (LanceDB-compatible shape) with optional embeddings + JSON profile | Permanent, indexed; cosine-ranked when the embeddings backend supplies vectors, keyword overlap otherwise |

**Memory Flow**:
1. User says something → goes into Working Memory and is mirrored clean into Episodic Memory via `mirrorTurn`: user/final text verbatim plus one compact `"Used <tool>: <outcome>"` record per meaningful tool execution, with interim narration and call-argument JSON skipped
2. Context fills → oldest working turns fold into the rolling session summary, keeping recent turns intact
3. Deterministic remember capture → `remember` / `remember that` / `/remember` parsed by `rememberFactText` and stored via `storeProfileFact` (`storeRememberedFact`), acknowledged without touching the LLM path
4. Key facts persist → stored in Semantic Memory with vectors from the configured embeddings backend (`apple` on-device default, `provider` opt-in, `none` keyword-only), mirrored into the JSON profile
5. On future queries → `memories.recall` merges episodic, semantic, and profile hits on one calibrated scale, sorted descending. Score ties break profile > semantic > episodic.

**Embeddings**: Semantic memory vectors flow through the `EmbeddingsBackend` seam (`EmbeddingsBackendFactory` selects from `memory.embedding_backend`). Facts without vectors persist as keyword-only rows; older rows gain vectors via embedding backfill. Dimension discipline keeps comparisons honest, and any embedding failure falls back to the keyword path (vectors never fail a turn or a write), while cancellation propagates instead of degrading.

**Document recall**: `memories.recall` also draws on the Document Index (§10) through `recallDocuments` / `MemoryEngine.recalledDocumentCandidates`, merging indexed document chunks onto the same calibrated scale so a question can surface a file, an email, or a message without a live walk. Candidates pair each FTS chunk with its parent document via the batch lookup `DocIndexStore.documents(ids:)` and carry source metadata (`path`, `display_name`, `document_source`, `mailbox`, `message_id`, chunk ordinal) so hits surface actionable file paths and mail identifiers. Results carry the index watermark so the model can tell how fresh the answer is.

### 5. Permission Gate & Sandboxing (shipped)

The permission system is the trust boundary between the agent and the real world.

**Permission Levels**:
- `readOnly` — Always allowed. Search, read, summarize. No approval needed.
- `requiresApproval` — Must be approved per-invocation by default.
- `trusted` — Auto-approved based on graduated trust policy.

**Graduated Trust**: allow this time / next 5 minutes / next 1 hour / next 1 day / forever, stored per-action-type per-target.

**Tool permission assignments**: `memories.store` and `memories.recall` are `trusted` per the owner memory-write ruling. `messages.search` and `messages.read` are `readOnly`. `messages.send`, `desktop.action`, `browser.act`, `api.request`, `media.arr`, `goal.create`, and `goal.progress` are `requiresApproval` and `messages.send` plus `desktop.action` are never `trusted`.

**Desktop safety invariants**: `desktop.screenshot` is `readOnly`; `desktop.action` is `requiresApproval` and never `trusted`. Enablement flows solely through the persisted tool-state toggle, which is the sole authority — the `[desktop]` section carries only capture knobs and never gates enablement. Control batches are bounded in count and delay, coordinates translate from screenshot space to native points, `blocked_apps` deny sensitive targets before dispatch, a cursor-in-corner fail-safe aborts the batch, and an operator emergency stop cancels the in-flight task. The menu-bar app surfaces an active indicator for exactly the dispatch window.

**Messages safety invariants**: reads use an isolated snapshot copy of `~/Library/Messages/chat.db` and never lock the live database. Sends sanitize text against AppleScript injection, reject null bytes, honour dry-run previews, and always park in the approvals inbox. Full Disk Access is required for reads; without it the tools fail closed with guidance.

**Sandbox (tiered)**:
- Tier 1/2 — Seatbelt-confinement for plugin subprocesses and document writes: downloads and edits use Seatbelt-confined temp with an atomic move into the workspace only on approval. There is no host staging directory.
- Tier 3 — Ephemeral microVM detonation for untrusted archives: Apple Container machines with manifest-only returns and immediate reap; crash-orphan reclamation only.
- Browser navigate/act calls each run in a fresh isolated Playwright context
- Python plugins run in subprocess sandboxes with timeouts and bounded output drains
- Network access is logged and auditable

### 6. Secrets Manager (shipped)

- **macOS Keychain**: Primary storage for API keys, passwords, tokens
- **Docker Vault** (optional): For self-hosted services (email IMAP credentials, etc.)
- **Config file**: `~/.runeweaver/config.toml` for non-sensitive settings only
- Secrets are never written to logs, never sent to LLMs, never stored in plaintext

### 7. Scheduler & Run Execution Engine (shipped)

- **Cron-like & Polling**: Five-field cron or named shortcuts plus email polling triggers.
- **SQLite as Durable Source of Truth**: All job definitions and execution audit logs reside in `~/.runeweaver/memory/episodes.db`. `config.toml` is strictly an initial bootstrap seed when the database has zero jobs.
- **In-Progress Run State Machine**: Every execution persists an in-progress run record tagged with a per-run `session_id` (fresh `UUID()`), broadcasting `run_started`/`run_completed` over WebSocket. Approval-gated turns park as `awaiting_approval` until the inbox decision resumes the same session (`ok` / `error` / `denied`). Stale `running` entries reconcile to `interrupted` on startup.
- **Per-Run Job Sessions & Visual Badging**: Each scheduled execution creates an independent session (fresh `UUID()` per run, `source: "scheduler"`), isolating background runs from interactive chat and from each other. Cross-run continuity flows through `SystemPromptComposer.composeScheduled` background prompting plus `run_logs` job linkage. Clients display scheduled sessions with distinct clock badges. The CLI-only deterministic session helper is not used by the service.
- **Two auto-fire runners, one at a time, plus per-process single-flight**: The service auto-fires in-process and the CLI foreground loop is a second runner in a separate process with no shared state — run one auto-fire runner at a time.

### 8. Voice Pipeline (partial)

- **STT**: Local Whisper model via CLI (`VoicePipeline`, `WHISPER_BINARY` or `PATH` resolution)
- **TTS**: System TTS (macOS `say`)
- Pipeline implemented; end-to-end push-to-talk UX is planned.

### 9. Client Layer

**macOS App — shipped**: Menu-bar app (always accessible) with chat window, approval notifications, scheduler summary, and dashboard/settings shortcuts. Its embedded service defaults to loopback (`127.0.0.1`) and resolves the same owner token as `serve`: it enforces the shared fail-closed bind policy (`ServerConfig.requireBindable`) and installs the bearer verifier once a token resolves, passing it into the served context so the bind posture and the request gate agree. Without a resolved token the service stays the loopback no-auth shape, so it never exposes an unauthenticated LAN bind. Dashboard and settings shortcuts open only a loopback address because the app never places the owner token in a URL. `isDesktopEnabled` derives from the live tool-state toggles (`toolBus.isToolEnabled` for `desktop.screenshot` / `desktop.action`, ORed together and re-read every poll tick): when either desktop tool is enabled the menu bar surfaces a Desktop Control section: an active indicator for exactly the dispatch window plus an operator emergency stop that cancels the in-flight control batch.

**Web Dashboard — shipped** (static bundle served by the engine): chat with session sidebar and clock-badged scheduled sessions; live tool-visibility frames; mid-turn cancellation; memory browser; scheduler management; run history with live tracking; parked-flight reconcile across reloads; client-side turn-cap enforcement mirroring the server; approvals inbox; search health and policy surfaces; spec-compliant markdown rendering with zero `dangerouslySetInnerHTML` and protocol-whitelisted URL sanitization; Web Notifications with unread badges over a shared WebSocket; when owner auth is active, the publicly served bundle renders its own in-bundle sign-in gate while every data route stays behind the uniform `401`. The Settings Tools tab renders each tool's Configure action solely from the server `hasConfig` flag on `GET /tools` (never a client name allowlist; `hasConfig` covers `bash.exec` plus `files.*` alongside desktop, media, and browser/web tools); it groups tools by name prefix into Desktop, Messages, Email, merged `browser-web` (Browser & Web covering `browser.*` plus `web.*`), `bash` (Bash & Shell), `files` (Files & Access), Memories, Goal and Tasks, Media, API / System, and `other` for external/unknown only, with instant search by name or description, category pill filters with count chips, per-category Enable All / Disable All bulk actions, section headers with counts, and one Configure modal per configurable category (desktop, media, browser-web, bash, files) including the unified Configure Desktop Integration modal that edits both capture bounds and the application safety blocklist in one place with a shared payload helper so full-save and modal-save stay symmetric. The Memory section hosts a tabbed header — the existing Search and Memory view plus an Index Status pane (§10) carrying the run/cancel/prune/reset controls — while the Settings surface's Indexing pane hosts only the index policy form (enable/sources/excludes/caps), so neither surface duplicates the other's controls.

**iOS App — planned**: SwiftUI client with push-to-talk and approval prompts. Remote engine access is gated by the owner token (presented as a bearer credential), with WireGuard recommended for off-LAN transport.

### 10. Document Index (shipped, opt-in)

A local, single-owner analogue of the pre-built search indexes that make cloud assistants feel fast: pay indexing cost once, then answer from the index instead of re-walking the world.

- **Opt-in by default**: `index.enabled` is `false`. A fresh install never reads a mailbox or walks the home directory until the owner turns it on. Per-source toggles gate files, mail, and Apple Messages independently; mail and Messages default off even once the master switch is on.
- **Storage**: One actor-backed SQLite database at `~/.runeweaver/index.db` (`DocIndexStore`, `DocIndexTypes`) holding `indexed_documents` and `indexed_chunks` plus an FTS5 virtual table over chunk text with sync triggers. Schema versioning and migration mirror the session-store pattern. Content-hash awareness means an unchanged document is skipped rather than re-extracted. Batch parent lookup `DocIndexStore.documents(ids:)` resolves a set of chunk parent IDs to full document rows in one round trip for recall enrichment.
- **Extraction**: `DocumentTextExtractor` (with `DocumentOfficeExtraction`) dispatches by format and reports an `ExtractStatus` — `extracted`, `partial`, `metadataOnly`, `unsupported`, `skippedEvicted`, or `failed`. PDFs use the native text layer; DOCX, XLSX, and PPTX are read from their package XML; text, Markdown, CSV, JSON, and HTML are decoded; iWork documents are best-effort because their body text is a binary payload. Unsupported formats never throw — they record a status and a reason. Text is chunked at roughly 512 tokens with overlap.
- **Sources**: `FilesIndexer` walks configured `roots` (default `~`) minus `exclude` plus always-skipped media libraries, `Library`, `.Trash`, the app's own state, and VCS/dependency/build/cache directories, pruning excluded directories without descending and never following symlinks and skipping Finder aliases without traversal, under `FilesAccessGuard` and the `max_file_mb` cap. `MailIndexer` reads bodies and attachments over IMAP using `BODY.PEEK` so nothing is marked read, stages attachments in Seatbelt-confined temp, extracts, then deletes the binary; oversize attachments are skipped and duplicates dedupe by content hash. `MessagesIndexer` reads an isolated snapshot of `~/Library/Messages/chat.db` (never locking the live database), parses `attributedBody` content and tapbacks via `MessagesDatabaseRow` / `MessagesAttachmentRow` / `MessagesDatabaseIO`, exposes `searchMessages` plus `conversationMessages`, and needs Full Disk Access.
- **Vectors**: Chunks are vectorized through the same `EmbeddingsBackend` seam as semantic memory when extraction is clean and the document is small; otherwise they stay keyword-only. Mail older than `mail_vector_window` is indexed but not vectorized, and can gain vectors later through backfill. An embedding failure degrades to keyword search rather than failing a run.
- **Freshness**: The index is built by a nightly (and on-demand) run and carries an `index_as_of` watermark. Live `email.search` and `files.grep` remain the fallback for today/this-morning/latest questions, and the system prompt tells the model to prefer them when the question implies recency.
- **Vision enrichment (opt-in)**: When `describe_images_with_llm` is on and the active provider reports `supportsVision`, image files and scanned PDFs that extracted as `metadataOnly` are described by the configured model, with the description stored as an additive chunk tagged by origin and model. A text-only provider is never sent image content.
- **Progress**: `IndexCoordinator` exposes `liveTotals` (phase/stage, `scanned`/`indexed`/`skipped`/`errors`, `rate` in docs/s from indexed over elapsed time, `elapsedMs`, `current`; nil when idle) mapped onto the additive `live` field on `GET /index/status`, plus `run_started`/`run_completed` over the WebSocket hub and a `run_logs` row per run. The dashboard polls status about every 2s while a run is in flight (paused when the tab is hidden, no idle polling) and renders the live block only from that polled snapshot; WebSocket `tool_progress` frames only trigger a re-poll and never carry counters. The live block unmounts when the engine clears `live` on settle, so no post-run summary persists in the live surface. There is no percentage bar; cancel is safe and resumable because committed batches are kept.
- **Maintenance**: The Memory → Index Status pane starts, cancels, prunes (older than a cutoff), and resets; the Settings → Indexing pane edits only the policy fields. Prune deletes older documents and their chunks; reset clears the whole index. Disabling the index or deleting the database leaves `memories.recall` with episodic and semantic memory only.

---

## INTEGRATIONS

### Shipped

**Email (self-hosted + iCloud IMAP, read + send)**:
- Search, read (read-only via `BODY.PEEK`), attachment download (Seatbelt-confined staging, per-file and total caps, approval-gated), send (approval-gated, logged). Passwords in Keychain, never in TOML.

**Apple Messages (native macOS, read + gated send)**:
- Search and read are read-only over a snapshot copy of `~/Library/Messages/chat.db` (Full Disk Access required, fail-closed with guidance when missing). Send is approval-gated, dry-run aware, and dispatched through AppleScript via `BoundedProcessRunner` with injection escaping. No message body is written to disk outside the snapshot temp copy.

**Browser automation and web access**: static search (`web.search`), static fetch (`web.fetch`), interactive browser (`browser.navigate` + `browser.act`), constrained API calls (`api.request`) — see Tool Plugin System. Screenshots opt-in per call, gated by model vision support.

**Desktop perception and gated control (shipped, off by default)**: `desktop.screenshot` (read-only display or named-app-window capture with downscaled JPEG, coordinate scales, content hash, optional window list) plus `desktop.action` (approval-gated bounded batch of app-switch, mouse, keyboard, scroll, and delay actions with screenshot-to-native translation). Native macOS bridges only; Screen Recording and Accessibility permissions fail closed with guidance when missing. Protected targets in `blocked_apps` refuse input before dispatch, a corner fail-safe aborts the batch, and the menu-bar app exposes an active indicator plus an operator emergency stop. Captures persist as hash-plus-metadata only.

**Media automation (Sonarr & Radarr, shipped)**: `media.arr` (approval-gated writes plus reads) and `media.arr.read` (approval-free reads) share one `MediaArrClient` execution path shaped by `ArrInstanceConfig` per service (`enabled`, `url`, `apiKeyEnv`, default quality profile, default root folder). Secrets never enter TOML, schemas, logs, or model output: only `api_key_env` names persist (`SONARR_API_KEY` / `RADARR_API_KEY` by default) and values resolve via `SecretsManager` (environment or Keychain `com.runeweaver.secrets`) at execution time. Every dial is LAN-scoped and bounded: the base URL must be absolute http(s) without credentials; metadata, link-local, and unspecified targets fail closed in any spelling while loopback and private-LAN ranges stay allowed so self-hosted instances keep working. Requests carry a 15s timeout and the `X-Api-Key` header, follow redirects manually within the shared redirect budget with per-hop re-validation, strip `X-Api-Key`/`Authorization` on cross-host moves (redacted `Location` on refusal), and fail closed past the response byte cap with a 1KB error-preview bound. An enabled entry with a blank or missing URL stays unconfigured — guidance, no dial — so stock installs fail closed until a base URL is set. Config round-trips through `ConfigTOML` (decode), `Config+Serialization` (encode), `Config+Validation` (bounds), and the `PUT /settings` partial `media` patch (`MediaSettingsUpdate` merge preserving untouched fields); the dashboard DTO mirrors the engine shape (`ArrServiceConfigData` backing both `SonarrConfigData` and `RadarrConfigData` aliases).

**Files & documents**: direct filesystem reads plus grep/glob via `FilesAccessGuard` (`deny_patterns`, `allow_roots`, `require_approval_on_deny`); writes use Seatbelt-confined temp with atomic move on approval.

**Local document index**: an opt-in index over files, mail, and Apple Messages that `memories.recall` searches by keyword (FTS5) and, when embeddings are on, by meaning — see Component Details §10. It stores content and derived vectors only; credentials resolve from the Keychain at run time and never enter the index.

### Planned (config knobs and marketplace stubs only — no tool implementations)

- **Apple Mail native read** (macOS framework integration)
- **HomeKit / Home Assistant control** (config schema exists; control tools not built)
- **Discord read**, **GitHub integration**, **Calendar integration**
- Marketplace entries for these exist only as curated metadata/scaffold stubs; they are not registered engine tools.

---

## SECURITY MODEL

### Principles
1. **Read by default, write with permission**: The agent can search and read freely. Anything that modifies state requires approval.
2. **Least privilege**: Each tool gets only the permissions it needs.
3. **Sandbox before trust**: New actions always start in the sandbox. Trust is earned through repeated safe execution.
4. **No secrets in prompts**: API keys and credentials are injected at execution time, never sent to the LLM as part of the prompt.
5. **Audit trail**: Every action the agent takes is logged (locally) with timestamps, inputs, and outcomes.

### Sandbox Architecture
```
~/.runeweaver/
├── config.toml          # Non-sensitive configuration
├── index.db             # SQLite: indexed documents, chunks, FTS5 + optional vectors
├── memory/
│   ├── episodes.db      # SQLite: conversation history (sessions, messages, episodes), scheduler jobs, run logs, plugin registry
│   └── vectors/         # JSON semantic-memory store (LanceDB-compatible shape: facts.json plus optional vectors)
├── logs/                # Audit trail
├── plugins/             # Installed tool plugins
└── voice/
    ├── whisper/         # Local Whisper model
    └── tts/             # TTS models/voice data
```

---

## MVP SCOPE (with build status — detail in ROADMAP.md)

### Phase 1: Foundation — shipped
- Core engine with LLM provider abstraction
- Basic conversation (text in/text out)
- Config file + provider setup
- Local LLM support (MLX on Apple Silicon, llama.cpp)

### Phase 2: Memory — shipped
- Conversation history (SQLite)
- Semantic memory (JSON store, LanceDB-compatible shape) + `memories.store` / `memories.recall` commands (legacy `remember_fact` / `recall_memories` aliases retained)
- Opt-in local document index over files, mail, and Apple Messages, feeding `memories.recall` with source-enriched candidates

### Phase 3: Email Integration — shipped except Apple Mail native (planned)
- IMAP reading (self-hosted + iCloud), summarization and search
- Email composition and attachment download (with approval)

### Phase 4: Browser & Multi-step — tools shipped, end-to-end email→web flows planned
- `web.search` / `web.fetch`, Playwright navigate + act, `api.request`
- Multi-step workflows (e.g., email → click link → confirm) remain hardening work

### Phase 5: Home & Communication — partial (Messages shipped, rest planned)
- Apple Messages read (`messages.search`, `messages.read`) plus approval-gated send (`messages.send` with dry-run preview) shipped; requires Full Disk Access for reads and always parks sends for approval
- HomeKit / Home Assistant control, Discord, Calendar, GitHub remain planned

### Phase 6: Voice & Polish — partial
- macOS menu-bar app shipped; Whisper STT + system TTS pipeline implemented; push-to-talk UX planned

### Phase 7: Self-Improvement — partial
- Plugin discovery, disabled-by-default holding pen, tamper detection, and marketplace UI shipped; registry install/update/remove flow planned

### Phase 8: Service & Runtime — shipped except launchd / iOS
- Vapor service (loopback by default, owner-auth LAN binds opt-in), single-owner bearer auth, static dashboard bundle, scheduler engine, approvals inbox shipped
- `launchd` daemon and iOS client planned; remote/VPN access uses the owner-token gate, with WireGuard recommended off-LAN

---

## CONFIGURATION

```toml
# ~/.runeweaver/config.toml

[engine]
name = "Rune Weaver"
log_level = "info"

[auth]
# Single-owner bearer token sources. The value never lives in this file.
# Resolution order: token_env, then the macOS Keychain account
# RUNEWEAVER_AUTH_TOKEN, then the 0600 token_file. A non-loopback bind
# requires a resolvable token.
# token_env = "RUNEWEAVER_AUTH_TOKEN"
# token_file = "~/.runeweaver/auth_token"

[llm]
default_provider = "mlx"
fallback_provider = "openrouter"

[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"  # MLX server (engine API binds 127.0.0.1:8082 to avoid colliding here; llama.cpp uses 8081)
# context_length = 8192  # optional override; omit for the backend default (MLX 8192, llama.cpp 4096, OpenAI-compatible 128000)

[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"  # Reads from env or Keychain
server_url = "https://openrouter.ai/api/v1"
# api_style = "chat-completions"  # chat-completions (default) | responses
# context_length = 128000  # e.g. 1000000 for 1M-context endpoints

[llm.providers.local]
enabled = false
provider_type = "llamacpp"
server_url = "http://localhost:8081"
# context_length = 4096
# slot_count = 4  # sticky id_slot pool size; match llama-server --parallel to opt into prefix reuse (omit for server auto-assign)
# cache_prompt = true  # prefix-cache hint (omit for default enabled; set false to disable)

[memory]
vector_db_path = "~/.runeweaver/memory/vectors"
episodes_db_path = "~/.runeweaver/memory/episodes.db"
embedding_model = "all-MiniLM-L6-v2"  # retained for forward compatibility; currently unused (apple = fixed on-device model, provider = active chat model, none = keyword-only)
embedding_backend = "apple"  # apple (on-device default) | provider (LLM embeddings opt-in) | none (keyword-only)

[voice]
stt_provider = "whisper"
whisper_model = "base"
tts_provider = "system"  # macOS say command

[sandbox]
# Tier-3 detonation only: ephemeral Apple Container microVMs with no host
# mounts. Document writes use Seatbelt-confined temp with an atomic move on
# approval. Legacy staging keys (staging_path, retention_days,
# max_total_bytes, cleanup_interval_seconds) and container_runtime are
# ignored with no migration. The runtime stays pinned to the Apple
# Container CLI.
container_base_image = "alpine:latest"  # OCI image for detonation guests
archive_session_ttl_minutes = 10  # crash-orphan reclamation TTL (1-1440)
max_concurrent_machines = 3  # concurrent detonation cap, enforced before spawn

[files]
deny_patterns = [".env*", ".netrc", "secrets.json", "config.toml", "*.pem", "*.key", "*keychain*", ".ssh/*", ".aws/*", ".runeweaver/memory/vectors/*", ".git-credentials", ".gitcookies", ".rclone.conf", ".npmrc", ".pypirc", ".Xauthority", ".emulator_console_auth_token", ".gnupg/*", ".kube/*", ".docker/*", ".config/gcloud/*", ".chia_keys/*", "*_history", ".zsh_sessions/*"]
allow_roots = ["~"]  # allowed roots for file reads (`~` expands to home)
require_approval_on_deny = true  # deny hits escalate to approvals inbox (true) or fail closed (false)

[index]
# Opt-in local document index. Off by default: a fresh install never reads a
# mailbox or walks the home directory until `enabled` is true. Content and
# derived vectors only — credentials resolve from the Keychain at run time.
enabled = false  # master switch
files = true  # local files under `roots`; on once the indexer is enabled
mail = false  # opt in to index a configured [email.accounts] mailbox
messages = false  # opt in to index Apple Messages (needs Full Disk Access)
roots = ["~"]  # directories scanned (`~` expands to home)
# Additional glob patterns skipped during a file scan; the walk always also
# skips media libraries (Music, Pictures, Movies), Library, .Trash, the app's
# own state, and common VCS/dependency/build/cache directories.
exclude = [".git", "node_modules", ".build", "DerivedData", "Library", ".Trash", "*.app"]
max_file_mb = 20  # largest file read (1-10240)
mail_vector_window = "2y"  # 30d | 6m | 1y | 2y | all — older mail stays keyword-only
icloud_evicted = "skip"  # skip | download — policy for iCloud files whose bytes are evicted
describe_images_with_llm = false  # describe images/scanned PDFs with the configured model
nightly_budget = 0  # items processed per run (0 = unlimited)
db_path = "~/.runeweaver/index.db"

[browser]
searxng_url = "http://127.0.0.1:8888"  # local SearXNG base URL (`/search` is appended)
search_timeout_seconds = 10  # per-search timeout (1-120)
max_results = 10  # per-search result cap (1-50, bounds web.search fan-out)

[desktop]
# Native macOS perception and gated automation. Both tools always register
# (visible but disabled) and enablement flows solely through the persisted
# tool-state toggle, which is the sole authority: a tool stays disabled
# until an operator enables it (dashboard Tools tab / tool-state API).
# This section carries only capture knobs and never gates enablement.
# Retired `screen_capture_enabled`, `control_enabled`, and legacy `enabled`
# keys are silently ignored when present so old files load without migration.
# Captures are in-memory downscaled JPEGs; control batches park in the
# approvals inbox.
max_image_dimension = 1280  # longest-edge bound for vision models
jpeg_quality = 0.75  # in-memory JPEG quality
blocked_apps = ["Terminal", "iTerm2", "Keychain Access", "System Settings", "System Preferences", "1Password", "Bitwarden"]  # protected targets refuse input

[email]
[[email.accounts]]
name = "icloud"
type = "imap"
host = "imap.mail.me.com"
port = 993
username = "user@icloud.com"
# password stored in Keychain
# Optional SMTP overrides (omit for auto: derived host on 587 STARTTLS then 465 SSL, verified TLS only).
# smtp_host = "smtp.mail.me.com"
# smtp_port = 587
# smtp_security = "auto"  # ssl | starttls | auto (default auto)

[home]
[[home.homekit]]
enabled = true

[[home.home_assistant]]
enabled = true
url = "http://homeassistant.local:8123"
token_env = "HA_TOKEN"

[media.sonarr]
enabled = true
url = "http://localhost:8989"  # omit until a Sonarr instance is reachable; enabled without a URL stays unconfigured and never dials
api_key_env = "SONARR_API_KEY"  # env-var / Keychain name only; the key value never lives in this file
# default_quality_profile = "HD-1080p"  # optional override; omit to auto-detect from Sonarr
# default_root_folder = "/data/media/tv"  # optional override; omit to auto-detect from Sonarr

[media.radarr]
enabled = true
url = "http://localhost:7878"  # omit until a Radarr instance is reachable; same fail-closed rule as Sonarr
api_key_env = "RADARR_API_KEY"  # env-var / Keychain name only
# default_quality_profile = "HD-1080p"  # optional override; omit to auto-detect from Radarr
# default_root_folder = "/data/media/movies"  # optional override; omit to auto-detect from Radarr

[scheduler]
# Cron fires use five-field expressions or @hourly / @daily / @weekly shortcuts.
# Poll entries watch one [email.accounts] entry for unseen arrivals.
# NOTE: config [[scheduler.jobs]] is only a bootstrap seed when the SQLite
# database has zero jobs; runtime edits persist to SQLite (see Scheduler docs).
# Known v1 limitation: single-flight is per-process only, so do not run the
# service auto-fire and the CLI foreground loop for the same job at once.

[[scheduler.jobs]]
name = "morning digest"
schedule = "0 8 * * *"
prompt = "Summarize overnight mail and today's calendar"
enabled = true

[plugins]
# External tool discovery. Discovered runes enter disabled, awaiting approval,
# and run as sandboxed subprocesses via JSON-RPC 2.0 over stdin/stdout.
plugins_dir = "~/.runeweaver/plugins"
marketplace_index_url = "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json"
auto_rescan = true

[security]
# Harness defense policy. Both keys default ON; an absent section loads
# hardened so existing files need no migration, and every key renders on save
# so a round-trip never depends on an implicit default.
untrusted_labeling = true  # wrap network tool output as data-only context (debugging off-switch)
email_credential_filter = true  # redact codes and credential links from agent-visible mail
```

---

## DECISIONS & CONSTRAINTS

### Key Decisions

1. **Swift over Python for core**: Performance, type safety, native Apple integration. Python is for plugins only.
2. **Actor model for concurrency**: Each subsystem (LLM, tools, memory) is a Swift actor, preventing data races.
3. **WebSocket for client-server & Ephemeral Browser Sessions**: Low-latency, bidirectional. Clients connect over loopback by default, and a non-loopback bind requires the owner token. Browser dashboard login exchanges the master owner token via `POST /auth/session` for an ephemeral, actor-managed session token stored in an `HttpOnly`, `SameSite=Strict` `rw_session` cookie; the master bearer token is never placed in cookies or persisted in client storage by the app. Ephemeral sessions are tracked in-memory by the `ServerAuth` actor (capped at 100 concurrent sessions) and are invalidated server-side on `DELETE /auth/session` as well as flushed automatically upon token rotation (`POST /auth/rotate`). The `Secure` cookie flag is proxy-aware. The WebSocket upgrade dials `/ws` with no query ticket and relies on the `rw_session` cookie; REST callers may use the same cookie or an `Authorization: Bearer` header. WireGuard (or equivalent) is the recommended transport for off-LAN access.
4. **JSON vector store (LanceDB-compatible shape) with pluggable embeddings**: Semantic memory persists as JSON rows carrying optional embedding vectors scored by cosine similarity, falling back to keyword-only token overlap when no vector is available. The store exposes the LanceDB table shape so a native LanceDB binding can replace the file backend without changing callers, and the `EmbeddingsBackend` seam (`apple` on-device default, `provider` opt-in, `none` keyword-only) lets new models land without touching callers. ChromaDB rejected (server process, heavier footprint).
5. **Playwright over Selenium**: Modern API, better async support, multi-browser, cleaner subprocess model.
6. **Graduated trust over binary permissions**: More nuanced than "always ask" or "never ask." Respects user's comfort level.
7. **Native WebSocket & Web Notifications for the service, best-effort osascript retained for the CLI foreground loop**: The service and dashboard path uses native WebSocket push broadcasting (`WSHub` emits `run_started`, `run_completed`, `approval_request`) paired with standard HTML5 Web Notifications and unread badge counters. The service never shells to AppleScript except through the gated Messages send path. The CLI `scheduler run` foreground loop retains a best-effort local `osascript` display notification for CLI foreground runs only when a GUI session exists; failures never fail the run so headless operation stays silent.
8. **SQLite as Primary Source of Truth for Scheduler and Runs**: Scheduled jobs and run execution history are stored durably in SQLite (`episodes.db`), with real-time in-memory caching in `SchedulerStore` and `RunLogStore`. `config.toml` serves solely as a bootstrap seed on initial setup when 0 jobs exist in SQLite.
9. **Per-Run Job Sessions & Badged History**: Every service scheduler run executes within an independent session (fresh `UUID()` per execution, `source: "scheduler"`). Episodic history is per-execution by design; cross-run continuity flows through `SystemPromptComposer.composeScheduled` background prompting plus `run_logs` job linkage rather than one shared session per job name. The CLI-only deterministic session helper is not used by the service. Clients display scheduled sessions with visual clock badges.
10. **Dynamic System Prompt Composition & Narration Fallback**: The system prompt is assembled at runtime by `SystemPromptComposer`, introspecting the active `ToolBus`. Canonical memory names are advertised; aliases are never advertised. When local or smaller models output text describing tool execution rather than native function-calling tokens, `Orchestrator` splits the fallback by permission level: read-only requests execute directly, `requiresApproval` requests file approvals and park the turn until decided.
11. **Spec-Compliant Markdown & Protocol-Whitelisted Sanitization**: Spec-compliant `react-markdown` + `remark-gfm` with zero `dangerouslySetInnerHTML`. Links and images sanitized via a strict protocol whitelist blocking `javascript:`, `vbscript:`, `data:`, and protocol-relative `//` URLs. Rendered anchor `href` and image `src` values are normalized prior to protocol verification to defeat character-encoding and whitespace bypasses.
12. **Unified Toolchain & Multi-Ecosystem Security Audit**: A single `Makefile` standardizes workflows across both the Swift engine and Web dashboard (`build`, `test`, `lint`, `audit`). `make audit` covers both ecosystems: `npm audit` for Node/React dependencies and `osv-scanner` (with `trivy` fallback) scanning `Package.resolved`.
13. **App Transport Security (ATS) & Portable Local Network (LAN) LLM Resolution**: The macOS application bundle adheres to Apple's App Transport Security least-privilege model by enabling exclusively `NSAllowsLocalNetworking = true` in `Info.plist`, maintaining default-deny HTTPS for all public internet traffic. Zero hardcoded user domains or global arbitrary load overrides are permitted. `RuneWeaverLLM` transparently resolves multi-label cleartext HTTP hostnames via standard DNS; if and only if the host resolves to an RFC 1918 / RFC 4193 private IP, the client routes directly to the resolved private IP while preserving the original `Host` header.
14. **Plugin Architecture & Disabled-by-Default Security Holding Pen**: Runes run out-of-process via standard JSON-RPC 2.0 over stdin/stdout (`SubprocessToolBridge`), supporting Python and standalone compiled executables. In-process dynamic loading is explicitly omitted for crash isolation, memory safety, and Hardened Runtime compliance. New runes are quarantined disabled until human review; enabling records a deterministic SHA-256 directory-tree hash, and any later modification trips tamper detection and fails closed. External plugins may only use `readOnly` / `requiresApproval`. Protected engine paths are guarded via `PluginSecurity.isProtectedPath` in `PermissionGate`.
15. **Status lives in ROADMAP.md, not here**: Delivery status (shipped / partial / planned per capability) is owned by `ROADMAP.md`. This document must not become a release log: describe decisions, protocols, and constraints, and mark build-state explicitly where it matters.
16. **SSRF DNS Resolution Timeout & Fail-Closed Bounds (5.0s)**: DNS resolution within SSRF vetting (`ApiSSRFGuard.dnsResolutionTimeoutSeconds`) is set to 5.0 seconds. Because the SSRF engine strictly fails closed — refusing any hostname whose IP addresses cannot be verified before dialing — a shorter window produced false-positive denials under routine resolver latency. The constant is exposed on `ApiSSRFGuard` so integration tests can assert the active threshold without divergence.
17. **Opt-In Local Document Index with Content-Hash Incremental Refresh**: Fast recall comes from a pre-built local index, not from making live reads faster. The engine keeps one actor-backed SQLite store (`~/.runeweaver/index.db`) with FTS5 keyword search plus optional embeddings drawn from the same `EmbeddingsBackend` seam as semantic memory, covering files, mail, and Apple Messages. Indexing is off until the owner enables it, mail and Messages are independently opt-in, and the store holds content plus derived vectors only — never credentials. Runs are incremental: documents are keyed by content hash so unchanged material is skipped, mail advances a per-mailbox UID watermark, and Messages advances a ROWID watermark against an isolated snapshot. Extraction is best-effort per format with a recorded status rather than a capability flag, mail attachments are read with `BODY.PEEK` and their binaries deleted after extraction, and vectorization is bounded by a configurable mail window and a document-size rule. A vector failure degrades to keyword search. Live `email.search` and `files.grep` remain the freshness fallback, and the index advertises an `index_as_of` watermark so the model can prefer live reads for recency-sensitive questions. Recall enrichment pairs each chunk with its parent via `DocIndexStore.documents(ids:)` and surfaces `path`, `display_name`, `document_source`, `mailbox`, `message_id`, and chunk ordinal.
18. **Native Desktop Perception with Approval-Gated Control**: Desktop vision and automation live behind one `[desktop]` contract with a single persisted tool-state gate: both tools always register (never absent from `GET /tools`) but ship disabled, and the persisted tool-state toggle is the sole authority for enablement. The `[desktop]` section carries only capture knobs and never gates enablement; retired keys are silently ignored at the TOML layer so pre-contract configs load without migration and stay disabled until the operator opts in via tool-state. Capture is macOS-only (ScreenCaptureKit with Screen Recording permission), bounded and in-memory with screenshot-to-native scale metadata, and persists as hash-plus-metadata only through the shared vision gate. Control is macOS-only (Accessibility permission), bounded in batch size and delay, denied up front for `blocked_apps`, aborted by a cursor-in-corner fail-safe, cancellable by the menu-bar emergency stop, and always parks in the approvals inbox — never `trusted`. Registration is single-sourced (`DesktopTools.makeTools` via `BuiltinToolPlugins`) so CLI, menu-bar app, and serve expose the same set. The dashboard edits both halves through one unified Configure Desktop Integration modal.
19. **Host Header Validation, DNS Rebinding Defense & HTTP Boundary Protection**: `HostValidationMiddleware` inspects the inbound HTTP `Host` header on all requests, rejecting non-allowlisted hosts with `HTTP 403`. The base allowlist is loopback plus the literal configured bind hostname plus exact-only `[server] allowed_hosts` entries (at most 20 entries, each at most 253 characters; no schemes, wildcards, CIDR, or bare `*`; entries must not end with `.` — trailing-dot hosts including a bare `.` fail closed). Hosts match exact-only after lowercasing plus port stripping, so `example.com.` never matches `example.com`. An all-interfaces bind with a resolved owner token additionally opens the LAN family (RFC 1918 plus link-local, IPv6 ULA plus link-local, and `.local` mDNS names) while any other bind never widens implicitly. `[server]` bind keys persist to the file but require a restart (`requiresRestart: true`). A non-loopback hostname saves and boots only with a resolvable owner token. Defense-in-depth security headers (`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, conditional HSTS) are injected globally.
20. **Additive `[security]` Defense Policy with Default-ON Keys**: The harness carries one additive `[security]` section (`SecurityConfig`) with two default-ON booleans: `untrusted_labeling` and `email_credential_filter`. An absent section loads hardened; present-but-wrong-typed values throw; every key renders on save so round-trips never depend on an implicit default.
21. **Declaration-Driven Content Trust with Forge-Resistant Labeling**: Each tool declares its own `contentTrustLevel` (default `.trusted` via protocol extension); network-derived tools override to `.untrustedExternal`. `OrchestratorToolLoop.labeledResultContent` wraps only untrusted results via the single-sourced `ContentTrustLabeler`, plumbed from `[security] untrusted_labeling` as a debugging off-switch.
22. **Surrogate Credential References with Transport-Boundary Resolution and Echo Sweeping**: Agent-visible arguments never carry secret bytes: `SecretsManager.surrogate(for:)` issues validated `rwsecret:<key>` references, resolved just-in-time at the transport boundary through the same environment-first, Keychain-second path as `retrieve`. Unknown keys fail closed with typed `unknownSurrogate`; dry-run previews and approval targets keep the reference visible; resolved values sweep out of output echoes longest-first into `[redacted]`.
23. **Deterministic Credential Filtering for Agent-Visible Mail**: `EmailCredentialFilter` scans subjects and bodies model-free for one-time codes, magic links, and password-reset links with `none` / `suspicious` / `credentialBearing` verdicts. Every `agentVisible` envelope forwards `credentialFilterEnabled` so `false` passes through byte-identically; search, read, and the mail index gateway honor `[security] email_credential_filter` (default ON). The human inbox is untouched.
24. **Manual Redirects with Per-Hop Re-validation and Bridge-Hop Re-vetting**: `web.fetch` and `api.request` never auto-follow: `HTTPRedirectFollower` (5-hop budget, http(s)-only) plus no-redirect delegates surface each hop for manual re-validation against the shared allowlist plus the SSRF guard. `browser.navigate` / `browser.act` vet entry URLs through the canonical guard, then re-vet every bridge-reported redirect and landing URL before encoding; unsafe targets fail closed with a redacted `Location` note.
25. **Canonical Memory Tool Identity with Backward-Compatible Aliases**: Canonical names are `memories.store` and `memories.recall` (`trusted`). Legacy `remember_fact` and `recall_memories` resolve via `ToolBus.registerAlias(from:to:)` in `executeTool` and `toolNames`, registered once through `MemoryTools.registerMemoryAliases` from `BuiltinToolPlugins` and the CLI. The system prompt advertises canonical names only. Alias removal follows tool unregistration in both directions. Error copy names the canonical tool.
26. **Native Apple Messages Read plus Approval-Gated Send**: `MessagesIndexer` exposes `searchMessages` and `conversationMessages` over `MessagesDatabaseRow` / `MessagesAttachmentRow` / `MessagesDatabaseIO`, reading only an isolated snapshot copy of `~/Library/Messages/chat.db` (never locking live) and parsing `attributedBody` plus tapbacks; Full Disk Access is required and missing access fails closed with guidance. `MessagesTools` implements `messages.search` / `messages.read` as `readOnly` and `messages.send` as `requiresApproval` (never `trusted`), honouring `ToolContext.dryRun`, sanitizing AppleScript strings via `ProductionMessagesGateway` over `BoundedProcessRunner`, and rejecting null bytes. The `MessagesGateway` protocol plus `StubMessagesGateway` isolate unit tests. Indexing of Messages remains separately opt-in under `[index] messages`.
27. **Dashboard Tools Category Contract with Unified Desktop Modal**: The Tools tab groups by tool-name prefix into Desktop, Messages, Email, merged `browser-web` (Browser & Web covering `browser.*` plus `web.*`), `bash` (Bash & Shell), `files` (Files & Access), Memories, Goal and Tasks, Media, API / System, and `other` for external/unknown only (non-builtin plugin tools and unprefixed/unknown names fall through to `other` and never join a builtin section), with instant search over name plus description, category pills with count chips, per-category Enable All / Disable All bulk actions, and section headers with counts. Configure actions render solely from the server `hasConfig` flag on `GET /tools` (never a client name allowlist; `hasConfig` covers `bash.exec` plus `files.*` alongside desktop, media, and browser/web tools) — `hasConfig` sole authority for showing Configure. Each configurable category owns one modal per category (one Configure entry per integration surface, e.g. desktop, media, browser-web, bash, files) so a category header button opens that category's single editor whenever any rendered tool in the category reports `hasConfig`. Desktop capture bounds and the safety blocklist share one Configure Desktop Integration modal with a single payload helper so full-save and modal-save stay symmetric.

### Constraints

- **Apple Silicon required** for MLX provider. Intel Macs can use llama.cpp/vLLM/cloud only.
- **Owner-auth-gated remote access**: Phone-to-Mac Studio communication is enabled over LAN or WireGuard once an owner token is configured. The token guards every non-public path; WireGuard (or equivalent) is recommended so the engine stays off the physical LAN.
- **Single-owner design**: Exactly one bearer token serves one person. There are no per-user accounts and no per-user data split; multi-user auth is out of scope.
- **Fail-closed binding**: The engine binds loopback by default. A non-loopback interface is accepted only when an owner token resolves, and the service never silently downgrades to an unauthenticated LAN bind. An all-interfaces bind with owner auth opens the LAN family while a literal LAN-IP bind stays strict on its hostname plus exact-only `allowed_hosts`. `[server]` bind keys require a restart to take effect (`requiresRestart: true`).
- **Host Header Enforcement**: Inbound HTTP requests must target an approved host — loopback, the literal configured bind hostname, or an exact-only `allowed_hosts` entry — matched after lowercasing plus port stripping, with trailing-dot hosts (including a bare `.`) failing closed; the LAN family is additionally accepted only on an authenticated all-interfaces bind; all other hosts are rejected with `HTTP 403`.
- **Fail-Closed Client Auth Gate**: The web dashboard authentication gate strictly fails closed to `"required"` upon initial probe network failure or backend error.
- **Auth-before-exposure**: A non-loopback interface, VPN, tunnel, or port-forward exposure requires the owner token; no unauthenticated exposure is permitted.
- **ATS Local Networking Only**: The packaged macOS app enables only `NSAllowsLocalNetworking` under App Transport Security. All public internet communication must use HTTPS.
- **Local-first**: No data leaves the machine unless the user explicitly configures a cloud LLM provider. Image description for the index is the same bargain: it runs only when the owner enables `describe_images_with_llm`, and a remote provider sends that content off-device.
- **Opt-in indexing**: The document index is disabled on a fresh install and reads nothing until enabled. Mail and Apple Messages each require their own explicit opt-in, and Apple Messages additionally requires Full Disk Access.
- **Opt-in desktop with OS permissions**: Desktop tools always register but ship disabled, and enablement flows solely through the persisted tool-state toggle, which is the sole authority; each bridge additionally fails closed when its macOS permission is missing: capture requires Screen Recording, control requires Accessibility. Denials return guidance, never a silent empty result.
- **Messages requires approval to send**: `messages.send` is `requiresApproval` and never `trusted`. Reads fail closed without Full Disk Access. Sends honour dry-run previews and AppleScript injection escaping.
- **Default-ON hardening**: `[security]` is absent-hardened. Saved files always render both keys so the on-disk policy matches the running policy.
- **No live secrets in agent context**: Agent-visible arguments, previews, logs, and persisted envelopes carry only `rwsecret:<key>` references; live values resolve at the transport boundary and sweep longest-first to `[redacted]` on echo.
- **Fail-closed transport**: Surrogates naming an empty slot throw `unknownSurrogate` and dial nothing; redirects to non-web targets, unverified hosts, or past the 5-hop budget refuse with guidance and never auto-follow; bridge-reported hops re-vet before they enter output.
- **Bounds**: `memories.recall` limit 1–50 default 5; `messages.search` limit 1–50 default 10; `messages.read` limit 1–100 default 20; empty or whitespace-only text is rejected; AppleScript text rejects null bytes; unknown tool aliases return unknown-tool errors with `callID`.
- **macOS Sequoia or later** for full framework access.

### Code Commenting Guidelines

- **New-File Headers**: Every new source and test file must begin with a descriptive top-of-file header comment documenting the component's purpose, scope, and architectural role.
- **Intent Over Mechanics**: Inline and doc comments must explain the rationale, invariants, non-obvious logic, or edge cases rather than restating what the code does mechanically.
- **No Planning-Artifact References**: Code comments must never reference task IDs, session IDs, PR numbers, plan identifiers, or other transient planning artifacts.

---

## OPEN QUESTIONS

1. **iOS app distribution**: TestFlight for personal use? Or sideload via AltStore?
2. **Python bridge approach**: Decided — out-of-process subprocess JSON-RPC 2.0 (`SubprocessToolBridge`). PythonKit was considered and rejected (Hardened Runtime, crash isolation).
3. **Update mechanism**: How do plugin updates and core updates propagate?
4. **Offline capability**: What should the agent do when the Mac Studio is unreachable?
5. **Index freshness policy**: Is a nightly run plus on-demand adequate, or should hot paths (Documents, Desktop, recent mail) get a filesystem watcher for near-real-time freshness?

Decided: web dashboard framework is React + TypeScript + Vite, shipped as a static bundle served by the engine (`Web/*` built to `Web/dist` via `DashboardBundle`).