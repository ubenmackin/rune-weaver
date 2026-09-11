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

LANGUAGE: Swift (core engine + iOS/macOS client), Python (tool plugins where ML/integration libraries require it)

### Why Swift First
- Native macOS/iOS integration (Apple Mail, HomeKit, Keychain, AppKit/SwiftUI)
- Strong type system, memory safety, great performance on Apple Silicon
- User's primary development language — fast iteration
- Swift concurrency (async/await, actors) is ideal for the async nature of LLM inference and tool orchestration

### Why Python for Plugins
- ML ecosystem (Whisper, Playwright, email parsing libraries) is Python-first
- Plugin isolation: a bad Python plugin can't crash the Swift core
- Easy for community contributors to write new skills

---

## SYSTEM ARCHITECTURE

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLIENT LAYER                              │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐    │
│  │  iOS Client  │  │  macOS Client│  │   Web Dashboard    │    │
│  │   (SwiftUI)  │  │   (SwiftUI)  │  │   (React/Vue)      │    │
│  │              │  │              │  │                    │    │
│  │ Push-to-talk │  │ Menu bar app │  │  Chat interface    │    │
│  │ TTS playback │  │ TTS playback │  │  Config / settings │    │
│  │ Notifications│  │ Voice toggle │  │  Memory browser    │    │
│  └──────┬───────┘  └──────┬───────┘  └────────┬───────────┘    │
│         │                 │                     │                │
│         └─────────────────┼─────────────────────┘                │
│                           │                                      │
│                    WebSocket / REST                               │
│                    (via WireGuard VPN)                            │
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

---

## COMPONENT DETAILS

### 1. Core Engine (Swift)

The core engine is a Swift package that runs as a persistent process. It owns:

- **Orchestration**: Receives user input (text or voice transcription), routes it through the LLM, executes tool calls, and returns responses.
- **Conversation Manager**: Maintains session state, conversation history, and context windows. Manages multi-turn conversations.
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
  ├── MLXProvider        // Local models via MLX (Apple Silicon)
  ├── LlamaCppProvider   // Local models via llama.cpp server
  ├── VLLMProvider       // Local models via vLLM server
  ├── OpenAIProvider     // Cloud: OpenAI, OpenRouter, etc.
  ├── AnthropicProvider  // Cloud: Claude
  └── CustomProvider     // Any OpenAI-compatible endpoint
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
| **Episodic Memory** | Past conversation turns as raw per-turn rows | SQLite + FTS5 | Permanent, mirrored every turn via `mirrorTurn` for resume; `summarizeSessions`/`compactSessions` exist but are not wired into chat |
| **Semantic Memory** | Facts, preferences, user profile | JSON keyword store (LanceDB-compatible shape) + JSON profile | Permanent, indexed; vectors deferred pending an embeddings backend |

**Memory Flow**:
1. User says something → goes into Working Memory and is mirrored raw per-turn into Episodic Memory via `mirrorTurn` for session resume
2. Context fills → oldest working turns fold into the rolling session summary, keeping recent turns intact
3. Deterministic remember capture → `remember` / `remember that` / `/remember` parsed by `rememberFactText` and stored via `storeProfileFact` (`storeRememberedFact`), acknowledged without touching the LLM path
4. Key facts persist → stored in Semantic Memory as keyword-only rows (no embeddings yet), mirrored into the JSON profile
5. On future queries → `recall` merges episodic, semantic, and profile hits via keyword overlap (vector similarity deferred until a local embeddings backend exists)

Summarization helpers `summarizeSessions` (non-destructive per-session summaries) and `compactSessions` (replace old rows with a summary episode) exist on the episode store but are not called from chat paths.

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

### 7. Scheduler

- **Cron-like**: User-defined schedules for recurring tasks (e.g., "summarize my emails every morning at 8 AM")
- **Event-driven**: React to triggers (new email arrived, calendar event upcoming, webhook received)
- Built on `SwiftServiceLifecycle` for clean startup/shutdown

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

**Web Dashboard (React/Vue)**:
- Full chat interface
- Configuration / settings
- Memory browser (search what the agent remembers)
- Tool/plugin management
- Scheduler management
- Runs locally at `http://localhost:8080`

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
│   └── approved/        # Approved for real filesystem
├── memory/
│   ├── episodes.db      # SQLite: conversation history
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

[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"  # Reads from env or Keychain
base_url = "https://openrouter.ai/api/v1"

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
3. **WebSocket for client-server**: Low-latency, bidirectional. Clients connect over WireGuard VPN.
4. **JSON keyword store (LanceDB-compatible shape), vector deferred**: Semantic memory persists as keyword-only JSON rows scored by token overlap until a local embeddings backend exists. The store exposes the LanceDB table shape (append facts, cosine similarity, metadata filtering) so a native LanceDB binding can replace the file backend without changing callers. ChromaDB rejected (server process, heavier footprint).
5. **Playwright over Selenium**: Modern API, better async support, multi-browser, cleaner subprocess model.
6. **Graduated trust over binary permissions**: More nuanced than "always ask" or "never ask." Respects user's comfort level.

### Constraints

- **Apple Silicon required** for MLX provider. Intel Macs can use llama.cpp/vLLM/cloud only.
- **WireGuard VPN** required for phone-to-Mac Studio communication. No public internet exposure.
- **Single-user design** (v1): No multi-user auth. The agent serves one person.
- **Local-first**: No data leaves the machine unless the user explicitly configures a cloud LLM provider.
- **macOS Sequoia or later** for full framework access.

---

## OPEN QUESTIONS

1. **iOS app distribution**: TestFlight for personal use? Or sideload via AltStore?
2. **Web dashboard framework**: React vs Vue vs Swift-based (Vapor + Leaf)?
3. **Python bridge approach**: PythonKit vs subprocess IPC vs embedding CPython?
4. **Update mechanism**: How do plugin updates and core updates propagate?
5. **Offline capability**: What should the agent do when the Mac Studio is unreachable?