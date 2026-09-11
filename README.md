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
