# Rune Weaver — Architecture

## PROJECT SOUL

Rune Weaver is a personal AI assistant harness — a modular, privacy-first system that bridges your digital life across Apple ecosystem, self-hosted services, and the web. Inspired by Jarvis/Friday from Iron Man, it runs as an always-on "brain" on a Mac Studio, with thin clients (iPhone, MacBook) connecting to interact with it.

The name comes from JRPG lore: a Rune Weaver is a mage who inscribes and channels magical runes to shape reality. Our Rune Weaver inscribes digital "runes" (skills, integrations, memory) to shape your daily workflow.

### Core Philosophy

- **Local-first, cloud-optional**: Your data stays on your hardware by default. Cloud LLMs are an opt-in fallback, not a requirement.
- **Human-in-the-loop**: The agent reads freely but writes cautiously. Every action that changes state requires explicit permission — with graduated trust so you're not approving the same thing forever.
- **Modular by design**: Capabilities are plugins (runes). Add new ones without touching the core. The system learns, remembers, and grows.
- **Apple-native where it counts**: Deep integration with macOS, iOS, iCloud, Apple Mail, HomeKit — not bolted on, but foundational.
- **Swappable LLMs**: The brain is model-agnostic. Run Gemma 4 on MLX locally, switch to Qwen 3.8 via llama.cpp, or fall back to a cloud API — the tools and memory don't care which model is thinking.

---

## TECH STACK

LANGUAGE: Swift (core engine + iOS/macOS client), Python (tool plugins where ML/integration libraries require it), TypeScript + React + Vite (web dashboard static bundle served by the engine)

### Why Swift First
- Native macOS/iOS integration (Apple Mail, HomeKit, Keychain, AppKit/SwiftUI)
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
│  │  iOS Client  │  │  macOS Client│  │   Web Dashboard    │    │
│  │   (SwiftUI)  │  │   (SwiftUI)  │  │   (React + Vite)   │    │
│  │              │  │              │  │                    │    │
│  │ Push-to-talk │  │ Menu bar app │  │  Chat interface    │    │
│  │ TTS playback │  │ TTS playback │  │  Approvals inbox   │    │
│  │ Notifications│  │ Voice toggle │  │  Memory / Schedules│    │
│  └──────┬───────┘  └──────┬───────┘  └────────┬───────────┘    │
│         │                 │                     │                │
│         └─────────────────┼─────────────────────┘                │
│                           │                                      │
│                    WebSocket / REST                               │
│              (loopback only in v1; remote via VPN deferred)         │
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
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │  Email   │ │ Browser  │ │  Files   │ │   Home   │          │
│  │ (IMAP +  │ │(Playwrt) │ │ (local + │ │(HK + HA) │          │
│  │ Apple)   │ │          │ │  iCloud) │ │          │          │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘          │
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │ Discord  │ │  GitHub  │ │ Messages │ │ Calendar │          │
│  │          │ │          │ │ (Apple)  │ │          │          │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Future: Smart Home, Code, Custom Skills      │  │
│  └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### Engine-to-Service Shift

The core engine is shifting from a CLI-only tool to a local service that other UIs drive through one HTTP surface.

- **Vapor API layer**: A Vapor service fronts the core engine and exposes chat, health, tools, memory, approvals, runs, and scheduler operations as JSON routes. The dashboard and future clients call the engine through this layer; the CLI remains direct-core for v1 (`chat` and `scheduler run` link `RuneWeaverCore` directly via `CLIShared.makeToolBus` and `Orchestrator` instead of going through HTTP, so terminal use works with no service running). The service itself launches from the CLI binary via `rune-weaver serve`, which builds a `ServerContext` with `ServerContext.make(...)`, registers the shared plugin tools, configures a Vapor `Application` with `configureRuneWeaver(_:context:)`, and runs it.
- **WebSocket event hub & real-time streaming**: The service maintains a persistent WebSocket endpoint (`/ws`) managed by `WSHub`. Chat turns stream live text deltas (`WSStreamDelta`), tool invocations (`WSToolStartFrame`), and tool outcomes (`WSToolEndFrame`), tagged with `sessionID` to allow frontend views to multiplex over a single shared connection (`useSharedWebSocket`) without cross-session leakage. In-flight turns support mid-turn cancellation via WebSocket frame (`{"type": "cancel"}`) or REST (`POST /chat/cancel`), which aborts the underlying Swift task via `ActiveTurnTracker`.
- **Durable SQLite persistence for scheduler & run history**: Scheduled jobs (`scheduler_jobs` table) and execution audit logs (`run_logs` table) persist in SQLite (`episodes.db`). The `config.toml` `[[scheduler.jobs]]` table is used solely as an initial bootstrap seed when the database has zero jobs, preventing dual-maintenance configuration drift. Runtime edits persist immediately to SQLite, and run states (`running` -> `ok`/`error`/`cancelled`) are tracked live, with interrupted runs reconciled on restart.
- **Static dashboard bundle**: The web dashboard ships as a static bundle served by the engine itself. It chats, browses memory, inspects run history, manages schedules, and surfaces the approvals inbox in a browser with no separate frontend host process.
- **Same trust boundary**: Every service-triggered write still flows through the permission gate with graduated trust, sandbox staging, and the local audit trail. The service layer adds transport; it does not bypass approvals.
- **Localhost-only, no-auth v1**: The v1 service binds loopback (`127.0.0.1`) only with no auth, relying on local-process access for protection.
- **Auth-before-exposure rule**: Authentication must land before the service binds a non-loopback interface or leaves the machine. No VPN, tunnel, or port-forward exposure without auth. Remote access over WireGuard (or any non-loopback transport) is deferred until auth lands; the service refuses non-loopback binds in v1.
- **Known v1 limitation — split-brain single-flight**: Scheduler single-flight is per-process only. `SchedulerRunLock` guards concurrent `POST /scheduler/jobs/:id/run` calls inside the service process and `SchedulerEngine.running` guards overlapping fires inside the CLI `scheduler run` foreground loop, but the two live in separate processes with no shared state, so the same job name can still run concurrently via API plus CLI in v1. A cross-process lock (file lock under `~/.runeweaver/` or SQLite) is deferred; do not run manual API runs and the CLI foreground loop for the same job at the same time.

---

## COMPONENT DETAILS

### 1. Core Engine (Swift)

The core engine is a Swift package that runs as a persistent process. It owns:

- **Orchestration**: Receives user input (text or voice transcription), routes it through the LLM, executes tool calls, and returns responses.
  - **Dynamic System Prompt Composition**: `SystemPromptComposer` snapshots the live tool registry (`ToolBus.availableTools()`) at session start and generates a deterministic system prompt including tool names, descriptions, input schemas, permission levels, tool-use policies, and memory guidance.
  - **Narration Fallback for Local LLMs**: When local or quantized models (e.g. Gemma, Qwen on MLX / llama.cpp) output text narration (`Calling <tool> with arguments {...}`) instead of structured function calling, `OrchestratorToolLoop` extracts and executes read-only tool calls with fresh call IDs, while keeping approval-gated tools protected.
  - **In-Flight Turn Cancellation**: `ActiveTurnTracker` tracks running turn tasks across both WebSocket and REST routes, allowing callers to cleanly abort long-running turns.
- **Conversation Manager**: Maintains session state, conversation history, and context windows. Manages multi-turn conversations across durable SQLite tables (`sessions`, `messages`) and hydrates missing cache entries from disk.
- **LLM Router**: Abstracts LLM providers. Selects the active provider, handles fallback chains, manages API keys and connection pooling.

Key patterns:
- **Swift Actors** for concurrency isolation between components
- **Protocol-oriented design** so each subsystem (LLM, tools, memory) is defined by protocols, not concrete types
- **Combine/AsyncSequence** for streaming LLM responses

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

Provider config supports `api_style` (`chat-completions` default, `responses` opt-in for the `/responses` endpoint and SSE shape). The provider HTTP client sends `User-Agent: rune-weaver/<version>` on every request and `x-opencode-session` when a chat session ID is set.

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

**Python Plugin Bridge**: Python tools are wrapped in a Swift → Python bridge (via PythonKit or a subprocess IPC). The Python tool runs in a sandboxed subprocess and communicates via JSON-RPC over stdin/stdout.

### 4. Memory Engine

Three tiers of memory, each backed by different storage:

| Tier | What | Storage | Lifecycle |
|------|------|---------|-----------|
| **Working Memory** | Current conversation context | In-memory + SQLite sessions (Core Engine) | Session-scoped, oldest turns fold into a rolling summary when over budget |
| **Episodic Memory** | Past conversation turns as cleaned per-turn rows | SQLite + FTS5 | Permanent, mirrored clean every turn via `mirrorTurn` for resume; auto-compacts sessions older than 30 days when records exceed `maxEpisodicCount` (10,000) |
| **Semantic Memory** | Facts, preferences, user profile | JSON keyword store (LanceDB-compatible shape) + JSON profile | Permanent, indexed; vectors deferred pending an embeddings backend |

**Memory Flow**:
1. User says something → goes into Working Memory and is mirrored clean into Episodic Memory via `mirrorTurn` for session resume: user/final text verbatim plus one compact `"Used <tool>: <outcome>"` record per meaningful tool execution, with interim narration, `Calling ... [...]` placeholder lines, call identifiers, and call-argument JSON skipped
2. Context fills → oldest working turns fold into the rolling session summary, keeping recent turns intact
3. Deterministic remember capture → `remember` / `remember that` / `/remember` parsed by `rememberFactText` and stored via `storeProfileFact` (`storeRememberedFact`), acknowledged without touching the LLM path
4. Key facts persist → stored in Semantic Memory as keyword-only rows (no embeddings yet), mirrored into the JSON profile
5. On future queries → `recall` merges episodic, semantic, and profile hits via keyword overlap (vector similarity deferred until a local embeddings backend exists)

Summarization helper `summarizeSessions` (non-destructive per-session summaries) exists on the episode store; `compactSessions` (replace old rows with a summary episode) is called automatically by `MemoryEngine` when episodic storage exceeds `maxEpisodicCount` (10,000 records) to prune sessions older than 30 days.

**Embeddings**: Vector-backed semantic memory is deferred pending a local embeddings backend. Until then facts persist as keyword-only rows scored by token overlap. When available, embeddings are generated locally using a small model (e.g., `all-MiniLM-L6-v2` via sentence-transformers in Python, or a Swift-native embeddings model when available).

### 5. Permission Gate & Sandboxing

The permission system is the trust boundary between the agent and the real world.

**Permission Levels**:
- `readOnly` — Always allowed. Search, read, summarize. No approval needed.
- `requiresApproval` — Must be approved per-invocation by default.
- `trusted` — Auto-approved based on graduated trust policy.

**Graduated Trust**:
When approving an action, the user can choose:
- Allow this time
- Allow for next 5 minutes
- Allow for next 1 hour
- Allow for next 1 day
- Allow forever

Trust is stored per-action-type per-target (e.g., "send email to dr.smith@clinic.com" = trusted for 1 day).

**Sandbox**:
- All file writes go to a staging directory first (`~/.runeweaver/sandbox/`)
- Writes to real filesystem require explicit approval
- Browser automation runs in an isolated Playwright context
- Python plugins run in subprocess sandboxes
- Network access is logged and auditable

### 6. Secrets Manager

- **macOS Keychain**: Primary storage for API keys, passwords, tokens
- **Docker Vault** (optional): For self-hosted services (email IMAP credentials, etc.)
- **Config file**: `~/.runeweaver/config.toml` for non-sensitive settings (provider URLs, model preferences, feature toggles)
- Secrets are never written to logs, never sent to LLMs, never stored in plaintext

### 7. Scheduler & Run Execution Engine

- **Cron-like & Polling**: User-defined schedules for recurring tasks (5-field cron or named shortcuts like `@hourly`, `@daily`, `@weekly`) and email polling triggers (`pollAccount`, `pollQuery`, `pollIntervalSeconds`).
- **SQLite as Durable Source of Truth**: All job definitions (`scheduler_jobs` table) and execution audit logs (`run_logs` table) reside in `~/.runeweaver/memory/episodes.db`. The `config.toml` `[[scheduler.jobs]]` table is strictly an initial bootstrap seed when the database has zero jobs, preventing dual-maintenance configuration drift. Runtime edits from the web dashboard persist directly to SQLite.
- **In-Progress Run State Machine**: Every job execution begins by persisting an in-progress run record (`status: "running"`), broadcasting `run_started` across WebSocket subscribers, and updating the record upon completion (`status: "ok"`, `"error"`, or `"cancelled"`). On server startup, any stale `"running"` entries left by abnormal process termination are automatically reconciled to `"interrupted"`.
- **Deterministic Job Sessions & Visual Badging**: Each scheduled job executes within a deterministic session ID (`SchedulerEngine.deterministicSessionID(forJobNamed:)`) stamped with `source: "scheduler"` and titled with the job's name. This isolates background automated runs from interactive user chat sessions while preserving episodic memory continuity across repeated runs of the same job. Clients display scheduled sessions with distinct clock badges (`ClockIcon`).
- **Foreground loop plus per-process single-flight**: The CLI `scheduler run` foreground loop (`while true` plus `Task.sleep` at `--interval` cadence) is the sole auto-fire runner; the service exposes CRUD plus a manual `POST .../run` entry point and never auto-fires. Overlapping fires skip with a log line instead of stacking: `SchedulerEngine.running` guards the CLI loop and `SchedulerRunLock` guards concurrent manual runs inside the service process. Known v1 limitation: the two locks share no cross-process state, so the same job name can still run concurrently via API plus CLI (see the Engine-to-Service Shift).

### 8. Voice Pipeline

- **STT**: Local Whisper model (via `whisper.cpp` or Python `faster-whisper`)
- **TTS**: System TTS (macOS `say` command or a local model like Piper)
- **Input**: Push-to-talk on iOS (tap to start, tap to stop)
- **Output**: Routed to AirPods/HomePod when connected, otherwise device speakers

### 9. Client Layer

**iOS App (SwiftUI)**:
- Push-to-talk button (tap to toggle mic)
- Text input as primary fallback
- TTS output routed to connected audio devices
- Notification display for approval requests
- Voice synthesis for responses
- Minimal UI — the conversation IS the interface

**macOS Client (SwiftUI)**:
- Menu bar app (always accessible, non-intrusive)
- Quick-access chat window
- Approval notifications
- System audio integration

**Web Dashboard (static bundle served by the engine)**:
- Full chat interface with session history sidebar and distinct visual badging for scheduled job sessions (`ClockIcon` vs `ChatIcon`).
- Real-time tool execution visibility: displays in-flight tool start/end frames, input arguments, and completion outcomes live as the LLM works via shared `ToolActionRow` components.
- Interactive turn controls: supports prompt cancellation mid-stream with responsive input lock releasing.
- Memory browser (search what the agent remembers, inspect facts and profile attributes).
- Scheduler management (wizard-driven job creation, cron & poll triggers, toggle enable/disable, manual "Run Now").
- Run history inspector with live in-progress run tracking across page loads and route changes.
- Approvals inbox (approve-with-duration or deny gated writes).
- Spec-compliant markdown rendering via `react-markdown` and `remark-gfm` with zero `dangerouslySetInnerHTML`, GFM table support, fenced code blocks with language tags, and protocol-whitelisted URL sanitization on links and images.
- Native Web Notifications API integration and unread badge counters for background runs and pending approvals, powered by a shared WebSocket connection (`useSharedWebSocket`).
- Served by the Vapor API layer on loopback only; no separate frontend host process.

---

## INTEGRATIONS

### Email

**Apple Mail (iCloud)**:
- Via macOS `NSAppleScript` or `Message.framework` (read-only for MVP)
- Deeper integration via Apple Mail plug-in (future)

**Self-hosted (IMAP/SMTP)**:
- IMAP for reading (Swift NIO IMAP client or Python `imaplib`)
- SMTP for sending (Swift NIO or Python `smtplib`)
- Running in Docker on Linux homelab — connect via WireGuard

### Browser Automation

- **Playwright** (Python) running in a sandboxed subprocess
- Actions: navigate, click, fill forms, screenshot, extract content
- Sandboxed: new browser context per task, no cross-contamination
- Approval required for any action that submits data or clicks buttons on real websites

### Home Automation

**HomeKit**:
- Native via `HomeKit.framework` on macOS
- Control lights, scenes, accessories

**Home Assistant**:
- REST API or WebSocket API
- Discovery via mDNS on local network
- Entity control, state queries, automation triggers

### Communication

**Discord**:
- Bot API for reading server messages
- Notifications for mentions
- Summarization of channels

**Apple Messages**:
- Via macOS `NSAppleScript` or Messages framework (read-only for MVP)
- Future: send replies

**GitHub**:
- GitHub API for repo management, issue tracking, PR review
- Personal access token stored in Keychain

### Files & Documents

- **Local files**: Direct filesystem access via Swift `FileManager`
- **iCloud Drive**: Via `FilePresenter` / `NSMetadataQuery`
- **Supported formats**: txt, rtf, md, docx, xlsx, numbers, pdf, images, source code
- **Parsing**: Swift for text/markdown, Python libraries for docx/pdf/xlsx

---

## SECURITY MODEL

### Principles
1. **Read by default, write with permission**: The agent can search and read freely. Anything that modifies state requires approval.
2. **Least privilege**: Each tool gets only the permissions it needs. Browser automation can't read your email. Email tools can't control your home.
3. **Sandbox before trust**: New actions always start in the sandbox. Trust is earned through repeated safe execution.
4. **No secrets in prompts**: API keys and credentials are injected at execution time, never sent to the LLM as part of the prompt.
5. **Audit trail**: Every action the agent takes is logged (locally) with timestamps, inputs, and outcomes.

### Sandbox Architecture
```
~/.runeweaver/
├── config.toml          # Non-sensitive configuration
├── sandbox/             # Staging area for file writes
│   ├── pending/         # Awaiting approval
│   ├── approved/        # Approved for real filesystem
│   └── attachments/     # `email.attachment` downloads only (10 MB cap, requiresApproval)
├── memory/
│   ├── episodes.db      # SQLite: conversation history (sessions, messages, episodes), scheduler jobs, run logs
│   └── vectors/         # LanceDB: semantic memory
├── logs/                # Audit trail
├── plugins/             # Installed tool plugins
│   ├── email/
│   ├── browser/
│   ├── home/
│   └── ...
└── voice/
    ├── whisper/         # Local Whisper model
    └── tts/             # TTS models/voice data
```

---

## MVP SCOPE

### Phase 1: Foundation
- Core engine with LLM provider abstraction
- Basic conversation (text in/text out)
- Config file + provider setup
- Local LLM support (MLX on Apple Silicon)

### Phase 2: Memory
- Conversation history (SQLite)
- Basic semantic memory (LanceDB)
- "Remember this" / "What do you know about X" commands

### Phase 3: Email Integration
- IMAP reading (self-hosted)
- Apple Mail reading
- Email summarization and search
- Basic email composition (with approval)

### Phase 4: Browser & Multi-step
- Playwright integration
- Navigate, read, and interact with websites
- Multi-step workflows (e.g., email → click link → confirm on website)

### Phase 5: Home & Communication
- HomeKit control
- Home Assistant integration
- Discord reading
- Calendar integration

### Phase 6: Voice & Polish
- Push-to-talk (iOS)
- Local Whisper STT
- TTS output
- Menu bar app (macOS)

### Phase 7: Self-Improvement
- Plugin marketplace / skill registry
- Agent can suggest new skills based on usage patterns
- Community-contributed plugins

---

## CONFIGURATION

```toml
# ~/.runeweaver/config.toml

[engine]
name = "Rune Weaver"
log_level = "info"

[llm]
default_provider = "mlx"
fallback_provider = "openrouter"

[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"  # MLX server
# context_length = 8192  # optional override; omit for the backend default (MLX 8192, llama.cpp 4096, OpenAI-compatible 128000)

[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"  # Reads from env or Keychain
base_url = "https://openrouter.ai/api/v1"
# context_length = 1000000  # e.g. 1000000 for 1M-context endpoints

[llm.providers.local]
enabled = false
provider_type = "llamacpp"
server_url = "http://localhost:8081"

[memory]
vector_db_path = "~/.runeweaver/memory/vectors"
episodes_db_path = "~/.runeweaver/memory/episodes.db"
embedding_model = "all-MiniLM-L6-v2"

[voice]
stt_provider = "whisper"
whisper_model = "base"
tts_provider = "system"  # macOS say command

[sandbox]
staging_path = "~/.runeweaver/sandbox"
auto_approve_after = 5  # Auto-approve after 5 successful executions

[email]
[[email.accounts]]
name = "icloud"
type = "imap"
host = "imap.mail.me.com"
port = 993
username = "user@icloud.com"
# password stored in Keychain

[[email.accounts]]
name = "personal"
type = "imap"
host = "mail.yourdomain.com"
port = 993
username = "you@yourdomain.com"
# password stored in Keychain

[home]
[[home.homekit]]
enabled = true

[[home.home_assistant]]
enabled = true
url = "http://homeassistant.local:8123"
token_env = "HA_TOKEN"
```

---

## DECISIONS & CONSTRAINTS

### Key Decisions

1. **Swift over Python for core**: Performance, type safety, native Apple integration. Python is for plugins only.
2. **Actor model for concurrency**: Each subsystem (LLM, tools, memory) is a Swift actor, preventing data races.
3. **WebSocket for client-server**: Low-latency, bidirectional. Local clients connect over loopback in v1; remote access over WireGuard VPN is deferred until auth lands.
4. **JSON keyword store (LanceDB-compatible shape), vector deferred**: Semantic memory persists as keyword-only JSON rows scored by token overlap until a local embeddings backend exists. The store exposes the LanceDB table shape (append facts, cosine similarity, metadata filtering) so a native LanceDB binding can replace the file backend without changing callers. ChromaDB rejected (server process, heavier footprint).
5. **Playwright over Selenium**: Modern API, better async support, multi-browser, cleaner subprocess model.
6. **Graduated trust over binary permissions**: More nuanced than "always ask" or "never ask." Respects user's comfort level.
7. **Native WebSocket & Web Notifications for the service, best-effort osascript retained for the CLI foreground loop**: The service and dashboard path uses native WebSocket push broadcasting (`WSHub` emits `run_started`, `run_completed`, `approval_request`) paired with standard HTML5 Web Notifications (`Notification` API) and unread badge counters in the Web dashboard. Routing service notifications through AppleScript subprocesses would cause blocking I/O, create disruptive modal prompts, require brittle macOS Terminal / Script Editor automation permissions that fail in headless setups, background daemons, or containerized environments, and cannot reach remote web or mobile clients, so the service never shells to AppleScript. The CLI `scheduler run` foreground loop retains a best-effort local `osascript` display notification via `MacOSSchedulerNotifier` for CLI foreground runs only when a GUI session exists; the service never shells to `osascript` and notifies exclusively through WebSocket broadcast plus Web Notifications; failures never fail the run so headless operation stays silent. This split keeps browser delivery non-blocking, cross-platform, multi-subscriber, and honoring browser notification preferences, while preserving a local popup for terminal-driven runs.
8. **SQLite as Primary Source of Truth for Scheduler and Runs**: Scheduled jobs (`scheduler_jobs` table) and run execution history (`run_logs` table) are stored durably in SQLite (`episodes.db`), with real-time in-memory caching in `SchedulerStore` and `RunLogStore`. `config.toml` serves solely as a bootstrap seed on initial setup when 0 jobs exist in SQLite, avoiding dual-maintenance divergence between database state and config files.
9. **Deterministic Job Sessions & Badged History**: Every scheduler run executes within a deterministic session ID (`SchedulerEngine.deterministicSessionID(forJobNamed:)`) stamped with `source: "scheduler"` and titled with the job's name. This keeps automated task execution cleanly partitioned from interactive chat sessions while preserving episodic memory continuity across repeated runs of the same job. Clients display scheduled sessions with visual clock badges (`ClockIcon`).
10. **Dynamic System Prompt Composition & Narration Fallback**: The system prompt is assembled at runtime by `SystemPromptComposer`, introspecting the active `ToolBus` to inject tool names, descriptions, input schemas, permission levels, and memory policies into the LLM context. When local or smaller models (e.g. Gemma on MLX / llama.cpp) output text describing tool execution (`Calling tool_name with arguments {...}`) rather than native function calling tokens, `Orchestrator` uses `OrchestratorToolLoop.narratedToolCalls` as a safe fallback parser to convert valid read-only requests into structured calls, without bypassing approval gates.
11. **Spec-Compliant Markdown & Protocol-Whitelisted Sanitization**: Replaced custom regex markdown parsers with spec-compliant `react-markdown` and `remark-gfm` for full CommonMark and GitHub Flavored Markdown (tables, code fences, blockquotes, lists) with zero `dangerouslySetInnerHTML`. Sanitizes links and images using a strict protocol whitelist (`isSafeUrl`) that blocks `javascript:`, `vbscript:`, `data:`, and protocol-relative `//` URLs, while permitting relative dashboard navigation and secure external URLs.
12. **Unified Toolchain & Multi-Ecosystem Security Audit**: A single `Makefile` standardizes workflows across both the Swift engine and Web dashboard (`build`, `test`, `lint`, `audit`). `make audit` covers both ecosystems: `npm audit` for Node/React dependencies and `osv-scanner` (with `trivy` fallback) scanning `Package.resolved` against open-source vulnerability databases.

### Constraints

- **Apple Silicon required** for MLX provider. Intel Macs can use llama.cpp/vLLM/cloud only.
- **Remote access deferred until auth lands**: Phone-to-Mac Studio communication over WireGuard (or any non-loopback transport) is a deferred post-v1 path. V1 serves loopback only with no remote exposure.
- **Single-user design** (v1): No multi-user auth. The agent serves one person.
- **Localhost-only, no-auth v1**: The Vapor API layer and static dashboard bundle bind loopback (`127.0.0.1`) only with no auth in v1; local-process access is the protection boundary.
- **Auth-before-exposure**: Authentication must land before the service binds a non-loopback interface or is exposed beyond the machine (VPN, tunnel, or port forward).
- **Local-first**: No data leaves the machine unless the user explicitly configures a cloud LLM provider.
- **macOS Sequoia or later** for full framework access.

### Code Commenting Guidelines

- **New-File Headers**: Every new source and test file must begin with a descriptive top-of-file header comment documenting the component's purpose, scope, and architectural role.
- **Intent Over Mechanics**: Inline and doc comments must explain the rationale, invariants, non-obvious logic, or edge cases rather than restating what the code does mechanically.
- **No Planning-Artifact References**: Code comments must never reference task IDs, session IDs, PR numbers, plan identifiers, or other transient planning artifacts.

---

## OPEN QUESTIONS

1. **iOS app distribution**: TestFlight for personal use? Or sideload via AltStore?
2. **Python bridge approach**: PythonKit vs subprocess IPC vs embedding CPython?
3. **Update mechanism**: How do plugin updates and core updates propagate?
4. **Offline capability**: What should the agent do when the Mac Studio is unreachable?

Decided: web dashboard framework is React + TypeScript + Vite, shipped as a static bundle served by the engine (`Web/*` built to `Web/dist` via `DashboardBundle`).