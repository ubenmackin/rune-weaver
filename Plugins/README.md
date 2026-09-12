# Rune Weaver Plugins ("Runes")

Capabilities are plugins. Add new ones without touching the core.

## Swift plugins

Conform to `RuneWeaverCore.Tool`:

- `name` — stable identifier (e.g. `email.search`)
- `description` — when the LLM should use it
- `inputSchema` — JSON Schema for function calling
- `permissionLevel` — `readOnly`, `requiresApproval`, or `trusted`
- `execute(input:context:)` — the handler

Register with `ToolBus.register(_:)`. File writes go to
`~/.runeweaver/sandbox/` staging first; writes to the real
filesystem require approval.

## Python plugins

Python tools (Whisper, Playwright, email parsing) run in a sandboxed
subprocess and communicate via JSON-RPC over stdin/stdout. A bad
Python plugin cannot crash the Swift core.

## Permission levels

- `readOnly` — always allowed
- `requiresApproval` — approved per-invocation unless covered by a
  graduated-trust grant (5 min / 1 hour / 1 day / forever)
- `trusted` — auto-approved per trust policy

## Layout

Installed plugins live under `~/.runeweaver/plugins/`:

```text
~/.runeweaver/plugins/
├── email/
├── browser/
├── home/
└── ...
```

## Build, test, and lint

Use the `Makefile` at the repo root as the canonical way to build,
test, and lint (Swift engine plus web dashboard). The dashboard build
requires Node.js 20+ with npm at build time only.

```bash
make build        # Swift engine + dashboard bundle (Web/dist)
make test         # Swift tests + dashboard tests (vitest)
make lint         # Swift style gates + dashboard typecheck
make run ARGS="status"  # launch the engine
```

Target reference: `build`, `build-web`, `build-swift`, `test`,
`test-web`, `test-swift`, `lint`, `lint-web`, `lint-swift`, `run`,
`clean`, `all`. See the root `README.md` and `Web/README.md` for the
full table.
