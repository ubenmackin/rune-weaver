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
