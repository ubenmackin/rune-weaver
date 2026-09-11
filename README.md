# Rune Weaver

> Inscribe digital runes to shape your daily workflow — a personal AI assistant harness for the Apple ecosystem.

## What Is This?

Rune Weaver is a personal AI assistant harness — a modular, privacy-first system that bridges your digital life across Apple devices, self-hosted services, and the web. Inspired by Jarvis/Friday from Iron Man, it runs as an always-on "brain" on a Mac Studio, with thin clients (iPhone, MacBook, terminal) connecting to interact with it.

The name comes from JRPG lore: a Rune Weaver is a mage who inscribes and channels magical runes to shape reality. Here, runes are skills, integrations, and memory — small composable capabilities that shape your workflow.

## Key Features

- **Local-first**: Your data stays on your hardware by default. Conversation history lives in local SQLite, semantic memory in an embedded vector store. Cloud LLMs are an opt-in fallback, never a requirement.
- **Privacy-first**: Secrets (API keys, passwords, tokens) live in the macOS Keychain or environment variables — never in `config.toml`, never in logs, never in LLM prompts. File writes stage in `~/.runeweaver/sandbox/` until approved. Every action is logged locally with an audit trail.
- **Modular**: Capabilities are plugins ("runes"). Each tool is a self-contained module conforming to the `Tool` protocol — add email, browser, home automation, or your own skill without touching the core. Python tools run in sandboxed subprocesses so a bad plugin can't crash the Swift core.
- **Apple-native**: Deep integration with macOS and iOS where it counts — Apple Mail, Messages, HomeKit, Keychain, menu-bar and push-to-talk clients — built in Swift with actors and async/await, tuned for Apple Silicon.
- **Swappable LLMs**: The brain is model-agnostic. Run Gemma 4 on MLX locally, switch to Qwen via a llama.cpp server, or fall back to OpenRouter/cloud — the tools and memory don't care which model is thinking. The `LLMRouter` holds a priority-ordered provider list and falls through on failure.

## Quick Start

Prerequisites: macOS 14+ (Sequoia or later for full framework access), Apple Silicon recommended for MLX, Swift 6.0 toolchain, Xcode 16+.

```bash
# 1. Clone
git clone https://github.com/<you>/rune-weaver.git
cd rune-weaver

# 2. Build
swift build

# 3. Configure
mkdir -p ~/.runeweaver
cp Config/config.toml.example ~/.runeweaver/config.toml
# Edit ~/.runeweaver/config.toml (see CONFIG.md), then store secrets:
# e.g. export OPENROUTER_API_KEY="..."  (or store in Keychain via SecretsManager)

# 4. Run
swift run rune-weaver status          # check providers, memory, tools
swift run rune-weaver chat            # interactive REPL
swift run rune-weaver config show     # inspect resolved config
swift run rune-weaver memory search "project"  # search semantic memory
```

The CLI (`rune-weaver`) is the MVP interaction layer: `chat`, `config`, `memory`, and `status`. There is no web frontend in this MVP.

## Email in chat (find and summarize)

Chat starts with the IMAP tools registered and visible to the model (self-hosted plus iCloud):

- `email.search` — find messages by free text (subject, sender, body); returns ids, headers, and snippets.
- `email.read` — open one message by id; returns headers plus the text body. Attachments are listed with filename, MIME type, and byte size; use `email.attachment` to download.
- `email.attachment` — download one attachment by index into the sandbox staging area only (`sandbox/attachments/`, 10 MB cap, `requiresApproval`).

Search and read are `readOnly`, so they run with no approval prompts; `email.attachment` is `requiresApproval` and prompts before staging. The assistant calls them during a turn, reads the results, and summarizes in conversation. Verified live against Volcrypt IMAP and iCloud IMAP (`imap.mail.me.com:993`) read-only; there is no send path.

### Live run (reads only, never sends)

#### Volcrypt

1. Configure the Volcrypt account in `~/.runeweaver/config.toml` (see `Config/config.toml.example` and `CONFIG.md`):

```toml
[[email.accounts]]
name = "volcrypt"
type = "imap"
host = "mail.volcrypt.com"
port = 993
username = "you@volcrypt.com"
# password is never stored here
```

2. Provide the password without printing it — environment first, Keychain fallback (service `com.runeweaver.secrets`):

```bash
export EMAIL_VOLCRYPT_PASSWORD="..."
# Keychain alternative: store EMAIL_VOLCRYPT_PASSWORD under service com.runeweaver.secrets
```

The variable name is `EMAIL_<UPPERCASED_ACCOUNT_NAME>_PASSWORD` (here `EMAIL_VOLCRYPT_PASSWORD`). Lookup is environment first, then the Keychain item `(service: com.runeweaver.secrets, account: EMAIL_VOLCRYPT_PASSWORD)`.

3. Confirm the tools and account are registered:

```bash
swift run rune-weaver status
# Tools: active: email.attachment, email.read, email.search
```

```bash
swift run rune-weaver chat
# Tools: email.attachment, email.read, email.search.
# Email accounts: volcrypt (you@volcrypt.com@mail.volcrypt.com:993).
```

Account names match case-insensitively, so `volcrypt`, `Volcrypt`, and `VOLCRYPT` all resolve. Only the name plus `username@host:port` ever prints; passwords never appear in output, logs, or the model prompt.

4. Start chat and ask to find and summarize:

```bash
swift run rune-weaver chat
```

```text
you> Find emails about quarterly report on volcrypt
weaver> ◈ calling email.search ...
you> Summarize message 42 from volcrypt
weaver> ◈ calling email.read ...
```

The verified flow is search then read: `email.search` lists matching ids, headers, and 200-character snippets (plain text preferred, HTML stripped to text), then `email.read` returns headers plus the text body for one id. The model summarizes the returned headers and snippets/bodies inline.

#### iCloud (app-specific password)

iCloud uses the same read-only tools over `imap.mail.me.com:993`. Apple requires an app-specific password for IMAP — the Apple Account password never works here.

1. Generate an app-specific password (requires two-factor authentication on the Apple Account):

- Sign in at Apple Account (`account.apple.com`) > Sign-In and Security > App-Specific Passwords.
- Generate a new app-specific password (e.g. labeled `rune-weaver`), copy the generated value.
- To revoke later, return to the same screen and revoke the label; revoking only stops IMAP logins using that value.

2. Configure the iCloud account in `~/.runeweaver/config.toml` (see `Config/config.toml.example` and `CONFIG.md`):

```toml
[[email.accounts]]
name = "icloud"
type = "imap"
host = "imap.mail.me.com"
port = 993
username = "user@icloud.com"
# password is never stored here
```

3. Provide the app-specific password without printing it — environment first, Keychain fallback (service `com.runeweaver.secrets`):

```bash
export EMAIL_ICLOUD_PASSWORD="xxxx-xxxx-xxxx-xxxx"
# Keychain alternative: store EMAIL_ICLOUD_PASSWORD under service com.runeweaver.secrets
```

The variable name follows the same convention as every account, `EMAIL_<UPPERCASED_ACCOUNT_NAME>_PASSWORD` (here `EMAIL_ICLOUD_PASSWORD`). Lookup is environment first, then the Keychain item `(service: com.runeweaver.secrets, account: EMAIL_ICLOUD_PASSWORD)`. The value must be the generated app-specific password, never the Apple Account password.

4. Confirm the tools and account are registered:

```bash
swift run rune-weaver status
# Tools: active: email.attachment, email.read, email.search
```

```bash
swift run rune-weaver chat
# Tools: email.attachment, email.read, email.search.
# Email accounts: icloud (user@icloud.com@imap.mail.me.com:993).
```

Account names match case-insensitively, so `icloud`, `Icloud`, and `ICLOUD` all resolve. Only the name plus `username@host:port` ever prints; passwords never appear in output, logs, or the model prompt.

5. Start chat and ask to find and summarize:

```bash
swift run rune-weaver chat
```

```text
you> Find emails about quarterly report on icloud
weaver> ◈ calling email.search ...
you> Summarize message 42 from icloud
weaver> ◈ calling email.read ...
```

The verified iCloud flow is the same search-then-read: `email.search` against `INBOX` followed by `email.read` for one id, summarized inline by the model.

Reads open `INBOX` read-only and fetch with `(BODY.PEEK[])` so flags never change; TLS is always verified with a 30-second connect timeout; search uses `OR SUBJECT/FROM/BODY` via `CHARSET UTF-8` with a plain fallback; queries reject CR/LF and ids allowlist to UID syntax (`^[0-9][0-9:,]*$`) so crafted input cannot inject IMAP commands. Secrets are never printed, logged, or sent to the model — failures only echo the account name, host, port, username, and expected variable name.

Without credentials the tools report a missing-password hint instead of connecting; the offline fixture suite still covers search/read parsing:

```bash
swift test --filter RuneWeaverToolsTests
```

Verified live against both Volcrypt and iCloud mailboxes read-only. Attachments list with filename, MIME type, and byte size; use `email.attachment` to download into the sandbox staging area (10 MB cap, approval required).

## Memory in chat (automatic recall)

Every chat turn runs automatic recall before the LLM call, so the assistant remembers across sessions without being asked to look anything up:

- The current user message is the query to `MemoryEngine.recall(query:embedding:limit:)` with nil embeddings (keyword path), merging episodic turns (SQLite + FTS5) plus semantic and profile facts by token overlap.
- The top 5 hits inject as one ephemeral `system` message right after the system prompt and rolling summary, ahead of the live conversation. Each line is source-labeled (`[episodic]`, `[semantic]`, `[profile]`) under a `Relevant memories ...` header, so the model can attribute context.
- Injection is token-bounded (2000 characters including the header, roughly 500 tokens) with ellipsis truncation; turns with nothing scoring at or above threshold (0.1) send no recall block. Recall failures never fail the turn, the just-mirrored user turn is filtered as self-echo, and the recall block is never stored in working memory.
- Explicit writes stay on the `/remember <fact>` path and on-demand reads stay on the `recall_memories` tool; automatic recall is the unprompted read path between them.

### Live run (two sessions, reads only, never prints secrets)

1. In session A, remember one fact and note the session id:

```bash
swift run rune-weaver chat --session 11111111-1111-1111-1111-111111111111
```

```text
you> /remember my dog is named Biscuit
weaver> Remembered: my dog is named Biscuit
you> /exit
```

2. In a fresh session B, ask without mentioning the fact. The answer should use the injected `[profile]` context with no `recall_memories` tool call:

```bash
swift run rune-weaver chat
```

```text
you> What is my dog's name?
weaver> Your dog is named Biscuit.
```

3. Confirm the stored state with reads only (no secrets are printed):

```bash
swift run rune-weaver memory search "dog Biscuit"
swift run rune-weaver memory facts
```

A missing recall block means nothing scored above threshold; a wrong answer means the fact never stored (check the `Remembered:` acknowledgement in session A first).

## Architecture Overview

```
Clients (CLI / iOS / macOS, over WebSocket)
        │
        ▼
Core Engine (Swift actors)
  LLM Router ──► MLX │ llama.cpp │ OpenRouter/cloud
  Tool Bus ────► Email │ Browser │ Files │ Home │ Discord │ GitHub │ …
  Conversation Manager (session state, history)
        │
        ▼
Support services: Memory Engine (SQLite + vector) │
  Permission Gate (graduated trust + sandbox) │
  Scheduler │ Secrets Manager (Keychain) │ Voice (Whisper STT + system TTS)
```

- **Orchestration layer**: routes input through the LLM, dispatches tool calls via the Tool Bus, manages session context.
- **Memory engine**: three tiers — working memory (in-memory, session-scoped), episodic memory (SQLite + FTS5, auto-summarized), semantic memory (vector + SQLite, indexed with local embeddings).
- **Permission gate**: read freely, write cautiously. `readOnly` tools always run; `requiresApproval` tools need per-invocation approval unless covered by a graduated-trust grant (5 min / 1 hour / 1 day / forever); `trusted` tools auto-approve per policy.
- **Tool plugins**: Swift-native via the `Tool` protocol, or Python via a sandboxed subprocess bridge (JSON-RPC over stdin/stdout).

For the deep dive — component details, security model, integrations, MVP phases, and design decisions — see [ARCHITECTURE.md](ARCHITECTURE.md). For configuration see [CONFIG.md](CONFIG.md). For writing tools see [PLUGIN_DEV.md](PLUGIN_DEV.md).

## Project Layout

```text
Sources/RuneWeaverCore/    # Config, Tool protocol, memory, permissions, secrets
Sources/RuneWeaverLLM/     # MLX, llama.cpp, OpenAI-compatible providers + router
Sources/RuneWeaverTools/   # Built-in tool plugins
Sources/RuneWeaverVoice/   # Whisper STT + TTS pipeline
Sources/RuneWeaverClient/  # Client networking
Sources/RuneWeaverCLI/     # `rune-weaver` terminal (chat, config, memory, status)
Config/config.toml.example # Copy to ~/.runeweaver/config.toml
Plugins/                   # Plugin docs and examples
Tests/                     # Per-target test suites
```

## Contributing

1. Fork the repo and create a feature branch (`git checkout -b feat/my-rune`).
2. Follow the existing style: Swift actors for shared mutable state, protocol-oriented design (`Tool`, `LLMProvider`), and doc comments on all public types.
3. Add or update tests under `Tests/<Target>Tests/` for your change.
4. Keep secrets out of code and config — use `SecretsManager` (Keychain service `com.runeweaver.secrets`) and `*_env` config keys.
5. New tools belong in `Sources/RuneWeaverTools/` or `Plugins/` — never in `RuneWeaverCore`. See [PLUGIN_DEV.md](PLUGIN_DEV.md).
6. Open a pull request describing what changed and how you tested it.

## License

MIT License. See `LICENSE` for the full text.
