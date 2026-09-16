# Rune Weaver

A personal AI assistant that runs on your Mac. It chats, remembers facts, runs scheduled jobs, and calls local tools. Your data stays on your machine by default.

## What

Rune Weaver is a local-first harness. A Swift engine does the thinking and tool calls. A Mac app gives you the primary entry point with the engine and dashboard bundled in. A web dashboard gives you chat, approvals, memory, runs, schedules, and settings. A terminal gives you the same engine when you prefer the command line.

Runes are small plugins that add skills. The core stays small and each rune stays separate, so you can add email, browser, files, or your own tool without changing the core.

## Why use

- Local by default. Chat history lives in local SQLite. Memory lives in a local store. Cloud models are opt-in fallback, not required.
- Private by default. Keys and passwords live in the Keychain or environment, never in config files or logs. Writes that change state ask first.
- Plain to run. Download the app and launch it. One menu bar icon starts the engine and opens the dashboard.
- Swappable models. Use a local model, a local server, or a cloud endpoint. Tools and memory work the same either way.
- Search built in. SearXNG runs locally in an Apple Container machine for private web search. No Docker needed.

## Quick Start

### Run the app

This is the primary path for most users. You do not need Xcode, Swift, Node, or Vite. Everything is already built into the download.

1. Download the latest DMG from GitHub releases.
2. Open the DMG, drag Rune Weaver to Applications, then launch it.
3. The app lives in the menu bar and starts the engine for you.
4. Choose Open Web Dashboard from the menu bar icon, then open Settings.
5. Set your default provider and model, then Save. Open the Search pane and press Start to pull and run SearXNG.
6. Use the Chat tab in the same dashboard page. Approve or deny writes in the approvals inbox as they come in.

Config is stored at `~/.runeweaver/config.toml`. Edit it from the Settings page. You do not need to hand edit the file.

### Build from source

This path is for contributors who want to change the code. You need macOS with Xcode and Swift, plus Node for the dashboard build and the tools in the table below.

```bash
# 1. Clone and build (engine plus dashboard)
git clone https://github.com/<you>/rune-weaver.git
cd rune-weaver
make build

# 2. Start the engine service (API plus dashboard on loopback)
make run ARGS="serve"

# 3. Open the Settings web page first and fill in providers
# Open http://127.0.0.1:8082 in a browser, go to Settings.
# Set your default provider and model, then Save.
# Open the Search pane and press Start to pull and run SearXNG.
# Config is stored at ~/.runeweaver/config.toml but edit it from the page.

# 4. Chat
# Use the Chat tab in the same web page, or run in the terminal:
make run ARGS="chat"

# Check health any time (providers, memory, tools, search):
make run ARGS="status"
```

Search status shows in two places. The Profile menu in the top nav has a SearXNG row with a green or red dot, the URL as a tooltip, and Start and Stop buttons. The Settings Search pane has the same Start and Stop buttons plus health text. The `status` command prints `reachable` or `unreachable` for the configured URL.

Only three make commands cover daily dev use:

```bash
make build              # build engine plus dashboard bundle
make test               # run Swift plus dashboard tests
make run ARGS="<args>"  # run the engine, for example chat, serve, status
```

See CONTRIBUTING.md for the full contributor flow.

## Dependencies

App users can skip the build row. Install only what matches the features you use, in this order. The steps below assume you have Homebrew installed. If you do not use Homebrew, follow the official docs linked per tool.

| Order | Dependency | Needed for | Notes |
|-------|------------|------------|-------|
| 1 | Apple Container CLI (`container`) | SearXNG search and sandbox detonation | No Docker needed. The CLI ships the isolation used by search and untrusted files. |
| 2 | SearXNG image | Local web search | Pulled automatically on first Start from the Settings Search pane or the Profile menu. First pull is about 150 MB, later starts reuse it. |
| 3 | Python 3 plus Playwright plus Chromium | Browser automation tools | Needed only if you use browser tools. See install steps below. |
| 4 | Whisper (optional) | Voice input | Needed only if you use speech to text. Skip it for text chat. See install steps below. |
| 5 | Xcode plus Swift plus Node plus Vite (contributors only) | Building from source with `make build` | Not needed for the DMG app. The app bundles the built dashboard, so no Node server runs in normal use. |

### Python 3

The engine shells out to `python3` for email and browser bridges. You need Python 3.10 or later.

```bash
brew install python
python3 --version
```

If you do not use Homebrew, get an installer from the official docs: https://www.python.org/downloads/

### Playwright plus Chromium

Needed only if you use the browser tools. Install the Python package, then download Chromium:

```bash
python3 -m pip install playwright
python3 -m playwright install chromium
```

The short form `pip install playwright` plus `playwright install chromium` works too when your `pip` points at the same Python. If you do not use Homebrew Python, follow the official docs: https://playwright.dev/python/docs/intro

### Whisper

Needed only if you use speech to text. Pick one of the two options.

Option A is the compiled binary, which is the smaller install:

```bash
brew install whisper-cpp
which whisper-cpp
```

The engine also looks for `whisper-cli`, `whisper`, and `main` on PATH, so any of those names works.

Option B is the Python package:

```bash
python3 -m pip install openai-whisper
```

If you do not use Homebrew, follow the official docs for either build: https://github.com/ggerganov/whisper.cpp or https://github.com/openai/whisper

### Xcode, Swift, Node

Contributors only. The DMG app does not need any of this.

- Install Xcode from the App Store, then check `swift --version` for Swift 6.
- Install Node 20 or later with `brew install node`, then check `node --version`.
- Vite ships with the repo `Web` dependencies, so `make build` handles it once Node is present. If you do not use Homebrew, get Node from: https://nodejs.org/

## Links

- [ARCHITECTURE.md](ARCHITECTURE.md) for the architecture overview, project layout, security model, and design notes.
- [CONTRIBUTING.md](CONTRIBUTING.md) for how to contribute.
- [CONFIG.md](CONFIG.md) for the full config reference. The Settings page writes the same file, so prefer the page over hand edits.
- [PLUGIN_DEV.md](PLUGIN_DEV.md) for how to write a rune.
- [Web/README.md](Web/README.md) for dashboard development.

## License

MIT License. See `LICENSE` for the full text.
