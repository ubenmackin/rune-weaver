# Contributing

How to build, test, run, and add a rune. Keep changes small and match the surrounding style.

## Build

```bash
make setup              # install Web and Swift dependencies
make build              # engine plus dashboard bundle (Web/dist)
```

Node plus Vite is build-time only. The engine serves the built files, so no Node server runs in normal use. You need macOS with Xcode and Swift, plus the tools in the README Dependencies table.

## Test

```bash
make test               # Swift suite plus dashboard tests (vitest)
make lint               # tsc --noEmit plus swiftformat and swiftlint
make audit              # npm audit plus osv-scanner or trivy on Package.resolved
```

## Run

```bash
make run ARGS="serve"   # start the API plus dashboard on loopback
make run ARGS="chat"    # terminal chat against the same engine
make run ARGS="status"  # provider, memory, tool, and search health
```

Open the Settings web page first (http://127.0.0.1:8082) and fill in providers before chatting. Config lives at ~/.runeweaver/config.toml. Prefer the Settings page over hand edits.

## Adding a rune

Runes are small plugins that add skills without changing the core. See PLUGIN_DEV.md for the Tool protocol, permission levels, and testing pattern.

Rules:

- Name tools `domain.verb` in lowercase and never rename once shipped.
- Pick `readOnly` for reads. Pick `requiresApproval` for anything that changes state.
- Honor dry runs. Return a preview without acting when the context asks for one.
- Keep secrets out of descriptions, schemas, logs, and errors. Resolve them at execution time.
- Add unit tests under `Tests/<Target>Tests/` that cover the handler, bad input, and registration.

## Wire and Configuration Casing

Rune Weaver enforces a strict single-casing model across layers:

| Layer | Casing | Rule |
|---|---|---|
| `config.toml` & `policy.toml` on disk | `snake_case` | Hand-written TOML parsers; user files on disk keep working |
| Swift & TypeScript in-memory models | `camelCase` | Standard language idiomatic casing |
| HTTP REST & WebSocket wire APIs | `camelCase` only | Single spelling per field on the wire; no snake_case aliases accepted or emitted |

Guidelines:
- Never add `snake_case` CodingKeys or aliases to Server DTOs or WebSocket wire frames.
- New fields must use `camelCase` on the wire and `snake_case` in disk TOML.
- Wire convention: use `memoryMb` (lowercase 'b') and `quotaMB` (uppercase 'MB').
- Contract tests in `Tests/RuneWeaverServerTests/WireCasingContractTests.swift` and `Web/src/wireCasing.test.ts` continuously enforce that no snake_case keys are emitted over the wire.

## Style

Every new source and test file starts with a header comment that states its purpose and role. Write comments that explain why, not what. Never reference task IDs, session IDs, or plan artifacts in code or comments.
