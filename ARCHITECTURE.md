# Rune Weaver — Architecture

## PROJECT SOUL

Rune Weaver is a personal AI assistant harness — a modular, privacy-first system that bridges your digital life across Apple ecosystem, self-hosted services, and the web. Inspired by Jarvis/Friday from Iron Man, it runs as an always-on "brain" on a Mac Studio, with thin clients connecting to interact with it.

The name comes from JRPG lore: a Rune Weaver is a mage who inscribes and channels magical runes to shape reality. Our Rune Weaver inscribes digital "runes" (skills, integrations, memory) to shape your daily workflow.

### Core Philosophy

- **Local-first, cloud-optional**: Your data stays on your hardware by default. Cloud LLMs are an opt-in fallback, not a requirement.
- **Human-in-the-loop**: The agent reads freely but writes cautiously. Every action that changes state requires explicit permission — with graduated trust so you're not approving the same thing forever.
- **Modular by design**: Capabilities are plugins (runes). Add new ones without touching the core. The system learns, remembers, and grows.
- **Apple-native where it counts**: Deep macOS integration (Apple Mail read path planned, Keychain, AppKit/SwiftUI) — not bolted on, but foundational. iOS is planned, not built.
- **Swappable LLMs**: The brain is model-agnostic. Run Gemma 4 on MLX locally, switch to Qwen 3.8 via llama.cpp, or fall back to a cloud API — the tools and memory don't care which model is thinking.

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
│  │  │             │  │              │  │  Manager      │  │    │
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
│  │  ┌─────────────┐  ┌──────────────┐                     │    │
│  │  │  Secrets    │  │  Voice       │                     │    │
│  │  │  Manager    │  │  Pipeline    │                     │    │
│  │  │             │  │              │                     │    │
│  │  │ Keychain +  │  │  Whisper STT │                     │    │
│  │  │ Docker vault│  │  TTS output  │                     │    │
│  │  └─────────────┘  └──────────────┘                     │    │
│  │                                                          │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                    TOOL PLUGINS                                   │
│              (shipped vs planned — see INTEGRATIONS)              │
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │  Email   │ │ Browser  │ │  Files   │ │  Memory  │          │
│  │ (IMAP +  │ │(Playwrt) │ │ (local)  │ │(remember │          │
│  │ send;    │ │          │ │          │ │+ recall) │          │
│  │ shipped) │ │ shipped  │ │ shipped  │ │ shipped  │          │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘          │
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │ Discord  │ │  GitHub  │ │ Messages │ │ Calendar │          │
│  │(planned) │ │(planned) │ │(planned) │ │(planned) │          │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘          │
│                                                                  │
│  ┌──────────┐ ┌──────────┐                                      │
│  │   Home   │ │Apple Mail│                                      │
│  │(planned) │ │(planned) │                                      │
│  └──────────┘ └──────────┘                                      │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Future: Custom Skills via plugin registry   │  │
│  └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

Shipped tool set: Email IMAP/SMTP (`email.search`, `email.read`, `email.attachment`, `email.send`, `email.listMailboxes`, `email.move`), web + browser (`web.search`, `web.fetch`, `browser.navigate`, `browser.act`, `api.request`), files (`files.read`, `files.grep`, `files.glob`), memory (`remember_fact`, `recall_memories`). Planned: Apple Mail native, HomeKit / Home Assistant control, Discord, GitHub, Apple Messages, Calendar (config knobs and marketplace stubs only — no tool implementations).

### Engine-to-Service Shift

The core engine is shifting from a CLI-only tool to a local service that other UIs drive through one HTTP surface.

- **Vapor API layer**: A Vapor service fronts the core engine and exposes chat, health, tools, memory, approvals, runs, and scheduler operations as JSON routes. The dashboard and future clients call the engine through this layer; the CLI remains direct-core for v1 (`chat` and `scheduler run` link `RuneWeaverCore` directly via `CLIShared.makeToolBus` and `Orchestrator` instead of going through HTTP, so terminal use works with no service running). The service itself launches from the CLI binary via `rune-weaver serve`, which builds a `ServerContext` with `ServerContext.make(...)`, registers the shared plugin tools, configures a Vapor `Application` with `configureRuneWeaver(_:context:)`, and runs it.
- **WebSocket event hub & real-time streaming**: The service maintains a persistent WebSocket endpoint (`/ws`) managed by `WSHub`. Chat turns stream live text deltas, tool invocations, and tool outcomes, tagged with `sessionID` so frontend views multiplex over a single shared connection (`useSharedWebSocket`) without cross-session leakage. In-flight turns support mid-turn cancellation via WebSocket frame (`{"type": "cancel"}`) or REST (`POST /chat/cancel`), which aborts the underlying Swift task via `ActiveTurnTracker`.
- **Authoritative concurrent-turn cap**: `ActiveTurnTracker.maxConcurrentTurns = 3` bounds simultaneous chat turns across REST and WebSocket (a replacement turn for the same session supersedes its slot; a fresh session past the cap fails with an honest busy notice). Every `GET /health` probe advertises the cap in the `X-RuneWeaver-Max-Concurrent-Turns` header alongside the JSON body so the dashboard prefers the server value and only falls back to its mirrored constant for older engines. `GET /health` also carries the live SearXNG Start flight stage (nil when idle).
- **Durable SQLite persistence for scheduler & run history**: Scheduled jobs (`scheduler_jobs`) and execution audit logs (`run_logs`) persist in SQLite (`episodes.db`). The `config.toml` `[[scheduler.jobs]]` table is used solely as an initial bootstrap seed when the database has zero jobs. Runtime edits persist immediately to SQLite, and run states (`running` → `ok`/`error`/`cancelled`, plus `awaiting_approval` → `ok`/`error`/`denied` for approval-gated parked turns) are tracked live, with interrupted runs reconciled on restart. Every `run_logs` row carries a nullable `session_id` column (backfilled via migration for older databases) linking the turn to its owning chat or per-run scheduler session (fresh `UUID()` per execution) so parked approvals resume in the same session.
- **Static dashboard bundle**: The web dashboard ships as a static bundle served by the engine itself. It chats, browses memory, inspects run history, manages schedules, and surfaces the approvals inbox in a browser with no separate frontend host process. When owner auth is active the bundle is still served publicly — a browser cannot attach a bearer header to a navigation or an asset fetch — and renders its own owner-token gate before any data request, so an unauthenticated visitor reaches the sign-in view instead of a dead end.
- **Same trust boundary**: Every service-triggered write still flows through the permission gate with graduated trust, sandbox staging, and the local audit trail. The service layer adds transport; it does not bypass approvals.
- **Single-owner bearer auth (shipped)**: Exactly one owner token guards the engine HTTP surface, whether it is launched through `rune-weaver serve` or the menu-bar app's embedded service. The token is a 256-bit URL-safe value minted by `rune-weaver auth token generate` and resolved at boot from `token_env`, then the Keychain account, then a `0600` `token_file`. It is verified in constant time, and failed non-loopback attempts throttle per client with `Retry-After`. Middleware gates every data path — REST and the WebSocket upgrade — returning the same uniform `401`; only the static dashboard bundle (which renders its own owner-token gate) and a minimal liveness shape are public, because a browser cannot attach a bearer header to a navigation or an asset fetch. The WebSocket query-token fallback requires a genuine `/ws` upgrade handshake (`Sec-WebSocket-Key` plus `Connection: upgrade` and `Upgrade: websocket`) and is stripped before any downstream log. Rotation persists the replacement before it goes live, but the two entry points differ in reach. The dashboard Settings pane rotates inside the running engine, so the previous token stops working immediately and established WebSockets are dropped. The CLI `rune-weaver auth token rotate` runs in a separate process and can only rewrite the stored credential, so a running engine keeps accepting the previous token until it is restarted; use the dashboard path when live revocation is required.
- **Fail-closed binding (shipped)**: Loopback (`127.0.0.1`, `localhost`, `::1`) always serves. A non-loopback bind — `serve --hostname <lan-ip>` or a non-loopback bind from the menu-bar app's embedded service — is accepted only when a token resolves (`ServerConfig.requireBindable`); otherwise boot is refused rather than silently downgraded to an unauthenticated LAN bind. WireGuard (or equivalent) remains the recommended transport off-LAN: it keeps the engine off the physical LAN while the bearer token still guards every request.
- **Service auto-fire plus per-process single-flight**: The service auto-fires scheduler cron and poll triggers in-process, sharing one lock with the manual run route so overlapping fires inside the service process skip with `409` instead of stacking. The CLI `scheduler run` foreground loop is a second auto-fire runner in a separate process with no shared state, so the same job name can still run concurrently via service plus CLI in v1 — run one auto-fire runner at a time.

---

## COMPONENT DETAILS

### 1. Core Engine (Swift)

The core engine is a Swift package that runs as a persistent process. It owns:

- **Orchestration**: Receives user input (text or voice transcription), routes it through the LLM, executes tool calls, and returns responses.
  - **Dynamic System Prompt Composition**: `SystemPromptComposer` snapshots the live tool registry (`ToolBus.availableTools()`) at session start and generates a deterministic system prompt including tool names, descriptions, input schemas, permission levels, tool-use policies, and memory guidance.
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

**Python Plugin Bridge**: Python tools run out-of-process via standard JSON-RPC 2.0 over stdin/stdout (`SubprocessToolBridge`) — PythonKit is explicitly not used, keeping crash isolation, memory safety, and macOS Hardened Runtime compliance. The Python tool runs in a sandboxed subprocess and communicates via JSON-RPC over stdin/stdout.

**Shipped built-in web and browser tools** (the shared five-tool set on `ToolBus`, same in CLI and serve, under one `[browser]` policy):

- `web.search` (`readOnly`): static search over self-hosted SearXNG JSON. The returned hit count is the smaller of the caller limit and `[browser] max_results`, so the model cannot fan out unbounded context.
- `web.fetch` (`readOnly`): bounded single-page read with per-hop allowlist checks, SSRF guard, redirect bound, byte cap, and a typed `ok` / `auth_required` / `unsupported` envelope.
- `browser.navigate` (`readOnly`): interactive page open over the isolated Playwright bridge in a fresh context with no persistent profile; returns distilled text plus snapshot refs.
- `browser.act` (`requiresApproval`): one validated action against a `browser.navigate` snapshot ref; every call parks in the approvals inbox; dry runs return a would-act preview.
- `api.request` (`requiresApproval`): constrained HTTP (GET, POST, PUT, DELETE) replacing shell curl, with allowlisted headers, body/response caps, per-hop SSRF checks, manifest-only file pulls, and dry-run previews.

**SearXNG lifecycle**: `SearXNGEnsurer.shared` keeps the local engine warm — ensured on `serve` boot and first search, single-flight in-process. The runtime is the Apple Container CLI only (`container`; Docker is unsupported) with loopback-only publish, a per-install settings file carrying a random secret (directory `0700`, file `0600`), and fail-closed guidance when down. The container stays running after quit by design; `rune-weaver status` reports `reachable`/`unreachable`.

**Navigate/act isolation**: navigate and act share one Playwright gateway but never share state. Each call opens a fresh isolated context with no persistent profile, no stored credentials, and no cross-task storage, then closes it before returning.

**Screenshot and vision gate**: `browser.navigate` carries an opt-in `includeScreenshot` flag (default false). Captures are bounded, held in memory for the turn only (never written to disk); only a content hash persists in the audit trail. The gate is model-aware: `VisionGate` strips image payloads for text-only models, `LLMRouter` hides `includeScreenshot` from tool schemas sent to text-only providers, and `SystemPromptComposer` advertises the opt-in only when `supportsVision` is true.

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
5. On future queries → `recall` merges episodic, semantic, and profile hits on one calibrated scale, sorted descending. Score ties break profile > semantic > episodic.

**Embeddings**: Semantic memory vectors flow through the `EmbeddingsBackend` seam (`EmbeddingsBackendFactory` selects from `memory.embedding_backend`). Facts without vectors persist as keyword-only rows; older rows gain vectors via embedding backfill. Dimension discipline keeps comparisons honest, and any embedding failure falls back to the keyword path (vectors never fail a turn or a write), while cancellation propagates instead of degrading.

### 5. Permission Gate & Sandboxing (shipped)

The permission system is the trust boundary between the agent and the real world.

**Permission Levels**:
- `readOnly` — Always allowed. Search, read, summarize. No approval needed.
- `requiresApproval` — Must be approved per-invocation by default.
- `trusted` — Auto-approved based on graduated trust policy.

**Graduated Trust**: allow this time / next 5 minutes / next 1 hour / next 1 day / forever, stored per-action-type per-target.

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
- **Two auto-fire runners, one at a time, plus per-process single-flight**: The service auto-fires in-process and the CLI foreground loop is a second runner in a separate process with no shared state — run one auto-fire runner at a time (see Engine-to-Service Shift).

### 8. Voice Pipeline (partial)

- **STT**: Local Whisper model via CLI (`VoicePipeline`, `WHISPER_BINARY` or `PATH` resolution)
- **TTS**: System TTS (macOS `say`)
- Pipeline implemented; end-to-end push-to-talk UX is planned.

### 9. Client Layer

**macOS App — shipped**: Menu-bar app (always accessible) with chat window, approval notifications, scheduler summary, and dashboard/settings shortcuts. Its embedded service defaults to loopback (`127.0.0.1`) and resolves the same owner token as `serve`: it enforces the shared fail-closed bind policy (`ServerConfig.requireBindable`) and installs the bearer verifier once a token resolves, passing it into the served context so the bind posture and the request gate agree. Without a resolved token the service stays the loopback no-auth shape, so it never exposes an unauthenticated LAN bind. Dashboard and settings shortcuts open only a loopback address because the app never places the owner token in a URL.

**Web Dashboard — shipped** (static bundle served by the engine): chat with session sidebar and clock-badged scheduled sessions; live tool-visibility frames; mid-turn cancellation; memory browser; scheduler management; run history with live tracking; parked-flight reconcile across reloads; client-side turn-cap enforcement mirroring the server; approvals inbox; search health and policy surfaces; spec-compliant markdown rendering with zero `dangerouslySetInnerHTML` and protocol-whitelisted URL sanitization; Web Notifications with unread badges over a shared WebSocket; when owner auth is active, the publicly served bundle renders its own in-bundle sign-in gate while every data route stays behind the uniform `401`. The live token is held in memory and mirrored only to `sessionStorage` (never persistent storage), logout or a uniform `401` returns to the gate, and the shared WebSocket presents the token as a query ticket restricted to the `/ws` upgrade.

**iOS App — planned**: SwiftUI client with push-to-talk and approval prompts. Remote engine access is gated by the owner token (presented as a bearer credential), with WireGuard recommended for off-LAN transport.

---

## INTEGRATIONS

### Shipped

**Email (self-hosted + iCloud IMAP, read + send)**:
- Search, read (read-only via `BODY.PEEK`), attachment download (Seatbelt-confined staging, per-file and total caps, approval-gated), send (approval-gated, logged). Passwords in Keychain, never in TOML.

**Browser automation and web access**: static search (`web.search`), static fetch (`web.fetch`), interactive browser (`browser.navigate` + `browser.act`), constrained API calls (`api.request`) — see Tool Plugin System. Screenshots opt-in per call, gated by model vision support.

**Files & documents**: direct filesystem reads plus grep/glob via `FilesAccessGuard` (`deny_patterns`, `allow_roots`, `require_approval_on_deny`); writes use Seatbelt-confined temp with atomic move on approval.

### Planned (config knobs and marketplace stubs only — no tool implementations)

- **Apple Mail native read** (macOS framework integration)
- **HomeKit / Home Assistant control** (config schema exists; control tools not built)
- **Discord read**, **Apple Messages read**, **GitHub integration**, **Calendar integration**
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
- Semantic memory (JSON store, LanceDB-compatible shape) + `remember` / recall commands

### Phase 3: Email Integration — shipped except Apple Mail native (planned)
- IMAP reading (self-hosted + iCloud), summarization and search
- Email composition and attachment download (with approval)

### Phase 4: Browser & Multi-step — tools shipped, end-to-end email→web flows planned
- `web.search` / `web.fetch`, Playwright navigate + act, `api.request`
- Multi-step workflows (e.g., email → click link → confirm) remain hardening work

### Phase 5: Home & Communication — planned
- HomeKit / Home Assistant control, Discord, Messages, Calendar, GitHub

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
deny_patterns = [".env*", ".netrc", "secrets.json", "config.toml", "*.pem", "*.key", "*keychain*", ".ssh/*", ".aws/*", ".runeweaver/memory/vectors/*"]
allow_roots = ["~"]  # allowed roots for file reads (`~` expands to home)
require_approval_on_deny = true  # deny hits escalate to approvals inbox (true) or fail closed (false)

[browser]
searxng_url = "http://127.0.0.1:8888"  # local SearXNG base URL (`/search` is appended)
search_timeout_seconds = 10  # per-search timeout (1-120)
max_results = 10  # per-search result cap (1-50, bounds web.search fan-out)

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
```

---

## DECISIONS & CONSTRAINTS

### Key Decisions

1. **Swift over Python for core**: Performance, type safety, native Apple integration. Python is for plugins only.
2. **Actor model for concurrency**: Each subsystem (LLM, tools, memory) is a Swift actor, preventing data races.
3. **WebSocket for client-server**: Low-latency, bidirectional. Clients connect over loopback by default, and a non-loopback bind requires the owner token. The WebSocket upgrade presents the token as a query ticket (browsers cannot set an `Authorization` header on a handshake) that the engine validates and strips before logging; REST and dashboard requests use the bearer header. WireGuard (or equivalent) is the recommended transport for off-LAN access.
4. **JSON vector store (LanceDB-compatible shape) with pluggable embeddings**: Semantic memory persists as JSON rows carrying optional embedding vectors scored by cosine similarity, falling back to keyword-only token overlap when no vector is available. The store exposes the LanceDB table shape (append facts, cosine similarity, metadata filtering) so a native LanceDB binding can replace the file backend without changing callers, and the `EmbeddingsBackend` seam (`apple` on-device default, `provider` opt-in, `none` keyword-only) lets new models land without touching callers. ChromaDB rejected (server process, heavier footprint).
5. **Playwright over Selenium**: Modern API, better async support, multi-browser, cleaner subprocess model.
6. **Graduated trust over binary permissions**: More nuanced than "always ask" or "never ask." Respects user's comfort level.
7. **Native WebSocket & Web Notifications for the service, best-effort osascript retained for the CLI foreground loop**: The service and dashboard path uses native WebSocket push broadcasting (`WSHub` emits `run_started`, `run_completed`, `approval_request`) paired with standard HTML5 Web Notifications and unread badge counters. The service never shells to AppleScript. The CLI `scheduler run` foreground loop retains a best-effort local `osascript` display notification for CLI foreground runs only when a GUI session exists; failures never fail the run so headless operation stays silent.
8. **SQLite as Primary Source of Truth for Scheduler and Runs**: Scheduled jobs and run execution history are stored durably in SQLite (`episodes.db`), with real-time in-memory caching in `SchedulerStore` and `RunLogStore`. `config.toml` serves solely as a bootstrap seed on initial setup when 0 jobs exist in SQLite.
9. **Per-Run Job Sessions & Badged History**: Every service scheduler run executes within an independent session (fresh `UUID()` per execution, `source: "scheduler"`). Episodic history is per-execution by design; cross-run continuity flows through `SystemPromptComposer.composeScheduled` background prompting plus `run_logs` job linkage rather than one shared session per job name. The CLI-only deterministic session helper is not used by the service. Clients display scheduled sessions with visual clock badges.
10. **Dynamic System Prompt Composition & Narration Fallback**: The system prompt is assembled at runtime by `SystemPromptComposer`, introspecting the active `ToolBus`. When local or smaller models output text describing tool execution rather than native function-calling tokens, `Orchestrator` splits the fallback by permission level: read-only requests execute directly, `requiresApproval` requests file approvals and park the turn until decided.
11. **Spec-Compliant Markdown & Protocol-Whitelisted Sanitization**: Spec-compliant `react-markdown` + `remark-gfm` with zero `dangerouslySetInnerHTML`. Links and images sanitized via a strict protocol whitelist blocking `javascript:`, `vbscript:`, `data:`, and protocol-relative `//` URLs.
12. **Unified Toolchain & Multi-Ecosystem Security Audit**: A single `Makefile` standardizes workflows across both the Swift engine and Web dashboard (`build`, `test`, `lint`, `audit`). `make audit` covers both ecosystems: `npm audit` for Node/React dependencies and `osv-scanner` (with `trivy` fallback) scanning `Package.resolved`.
13. **App Transport Security (ATS) & Portable Local Network (LAN) LLM Resolution**: The macOS application bundle adheres to Apple's App Transport Security least-privilege model by enabling exclusively `NSAllowsLocalNetworking = true` in `Info.plist`, maintaining default-deny HTTPS for all public internet traffic. Zero hardcoded user domains or global arbitrary load overrides are permitted. `RuneWeaverLLM` transparently resolves multi-label cleartext HTTP hostnames via standard DNS; if and only if the host resolves to an RFC 1918 / RFC 4193 private IP, the client routes directly to the resolved private IP while preserving the original `Host` header.
14. **Plugin Architecture & Disabled-by-Default Security Holding Pen**: Runes run out-of-process via standard JSON-RPC 2.0 over stdin/stdout (`SubprocessToolBridge`), supporting Python and standalone compiled executables. In-process dynamic loading is explicitly omitted for crash isolation, memory safety, and Hardened Runtime compliance. New runes are quarantined disabled until human review; enabling records a deterministic SHA-256 directory-tree hash, and any later modification trips tamper detection and fails closed. External plugins may only use `readOnly` / `requiresApproval`. Protected engine paths are guarded via `PluginSecurity.isProtectedPath` in `PermissionGate`.
15. **Status lives in ROADMAP.md, not here**: Delivery status (shipped / partial / planned per capability) is owned by `ROADMAP.md`. This document must not become a release log: describe decisions, protocols, and constraints, and mark build-state explicitly where it matters.

### Constraints

- **Apple Silicon required** for MLX provider. Intel Macs can use llama.cpp/vLLM/cloud only.
- **Owner-auth-gated remote access**: Phone-to-Mac Studio communication is enabled over LAN or WireGuard once an owner token is configured. The token guards every non-public path; WireGuard (or equivalent) is recommended so the engine stays off the physical LAN.
- **Single-owner design**: Exactly one bearer token serves one person. There are no per-user accounts and no per-user data split; multi-user auth is out of scope.
- **Fail-closed binding**: The engine binds loopback (`127.0.0.1`) by default. A non-loopback interface is accepted only when an owner token resolves, and the service never silently downgrades to an unauthenticated LAN bind. The macOS menu-bar app's embedded service shares this policy: it defaults to loopback, resolves the same owner token, and installs the bearer verifier when one resolves.
- **Auth-before-exposure**: A non-loopback interface, VPN, tunnel, or port-forward exposure requires the owner token; no unauthenticated exposure is permitted.
- **ATS Local Networking Only**: The packaged macOS app enables only `NSAllowsLocalNetworking` under App Transport Security. All public internet communication must use HTTPS.
- **Local-first**: No data leaves the machine unless the user explicitly configures a cloud LLM provider.
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

Decided: web dashboard framework is React + TypeScript + Vite, shipped as a static bundle served by the engine (`Web/*` built to `Web/dist` via `DashboardBundle`).