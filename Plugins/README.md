# Rune Weaver Plugins ("Runes")

Capabilities are plugins. Add new ones without touching the core.

## Swift plugins

Conform to `RuneWeaverCore.Tool`:

- `name` — stable identifier (e.g. `email.search`)
- `description` — when the LLM should use it
- `inputSchema` — JSON Schema for function calling
- `permissionLevel` — `readOnly`, `requiresApproval`, or `trusted`
- `contentTrustLevel` — `.trusted` (default) or `.untrustedExternal` (for network/external outputs)
- `execute(input:context:)` — the handler

Register with `ToolBus.register(tool:isEnabled:)`. File writes integrate with the review loop: staged writes persist to `StagedFilesStore` for inline review, while live writes create `.rune_backup_` rollback snapshots.

## Python plugins

Python tools (Playwright browser automation, email parsing helpers) run in a sandboxed subprocess and communicate via JSON-RPC 2.0 over stdin/stdout. A bad Python plugin cannot crash the Swift core. (Whisper speech-to-text runs as a standalone local CLI binary via `VoicePipeline`, not as a Python plugin.)

## Permission levels

- `readOnly` — always allowed (search, read, inspect)
- `requiresApproval` — approved per-invocation unless covered by a graduated-trust grant (5 min / 1 hour / 1 day / forever)
- `trusted` — auto-approved per trust policy (e.g. single-owner memory store/recall)

## Layout

Core tools (email, browser, files, bash, memory, goals, desktop, fan-out) are built directly into `Sources/RuneWeaverTools`.

Installed external community plugins live under `~/.runeweaver/plugins/`:

```text
~/.runeweaver/plugins/
├── custom-skill/
│   ├── manifest.json
│   └── ...
└── ...
```

Discovered plugins enter the system in a disabled state awaiting operator approval before they can execute on the live tool bus.

## Build, test, and lint

Use the `Makefile` at the repo root as the canonical way to build, test, and lint (Swift engine plus web dashboard). The dashboard build requires Node.js 20+ with npm at build time only.

```bash
make build        # Swift engine + dashboard bundle (Web/dist)
make test         # Swift tests + dashboard tests (vitest)
make lint         # Swift style gates + dashboard typecheck
make run ARGS="status"  # launch the engine
```

Target reference: `build`, `build-web`, `build-swift`, `test`, `test-web`, `test-swift`, `lint`, `lint-web`, `lint-swift`, `run`, `clean`, `all`. See the root `README.md` and `Web/README.md` for the full table.
