# Plugin Developer Guide ("Runes")

Capabilities are plugins. A plugin ("rune") is a self-contained module that gives the agent hands in the world — search email, click a web page, toggle a light. Add new ones without touching the core.

There are two flavors:

- **Swift plugins** — conform to `RuneWeaverCore.Tool`, register with `ToolBus`. Native speed, type safety, direct Apple framework access.
- **Python plugins** — for Whisper, Playwright, email parsing, and anything where the ML/integration ecosystem is Python-first. They run in a sandboxed subprocess and talk JSON-RPC over stdin/stdout, so a bad Python plugin can't crash the Swift core.

## The `Tool` Protocol

Every Swift tool conforms to `RuneWeaverCore.Tool` (`Sources/RuneWeaverCore/Tool.swift`):

```swift
public protocol Tool: Sendable {
    var name: String { get }                    // e.g. "email.search"
    var description: String { get }             // when the LLM should use it
    var inputSchema: JSONSchema { get }         // function-calling contract
    var permissionLevel: PermissionLevel { get } // trust requirement
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput
}
```

Supporting types (`Sources/RuneWeaverCore/ToolContext.swift`, `ToolOutput.swift`):

- `JSONSchema` — wraps the raw JSON Schema document (`rawValue: String`) describing the input arguments. Use `.emptyObject` (`{"type":"object"}`) for argument-free tools.
- `ToolInput` — `toolName`, `argumentsJSON` (raw JSON matching your schema), `callID` (correlation ID, defaults to a UUID).
- `ToolContext` — `conversationID` (owning session) and `dryRun` (when true, do not mutate external state). Secrets are injected at execution time via the context path — never read keys from the prompt.
- `ToolOutput` — `content`, `isError`, `callID`. Use `.success(_:callID:)` / `.failure(_:callID:)` conveniences; echo back `input.callID` so the orchestrator can correlate.

Registration: create your tool and call `ToolBus.register(_:)`. Installed plugin checkouts live under `~/.runeweaver/plugins/<name>/`.

## Minimal Example

A read-only clock tool — small enough to copy-paste, complete enough to show every piece:

```swift
import Foundation
import RuneWeaverCore

struct ClockTool: Tool {
    let name = "clock.now"
    let description = "Returns the current date and time. Use when the user asks what time it is."
    let inputSchema = JSONSchema(rawValue: #"{"type":"object","properties":{}}"#)
    let permissionLevel = PermissionLevel.readOnly

    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let formatter = ISO8601DateFormatter()
        return .success(formatter.string(from: Date()), callID: input.callID)
    }
}

// Somewhere at startup:
let bus = ToolBus()
await bus.register(ClockTool())
```

A tool with arguments declares them in the schema and parses `argumentsJSON`:

```swift
struct GreetTool: Tool {
    let name = "greet.person"
    let description = "Greets a person by name."
    let inputSchema = JSONSchema(rawValue: """
        {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
        """)
    let permissionLevel = PermissionLevel.readOnly

    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        struct Args: Decodable { let name: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(input.argumentsJSON.utf8))
        return .success("Hello, \(args.name)!", callID: input.callID)
    }
}
```

Guidelines:

- `name` — stable, dotted, lowercase (`domain.verb`: `email.search`, `files.read`). Never rename once shipped; the LLM and memory reference it.
- `description` — write for the LLM: say **when** to use the tool and what it returns, not how it works.
- `inputSchema` — keep it tight. Every required field is a chance for the model to hallucinate; prefer few required fields with clear types.
- `execute` — honor `context.dryRun` (return what you *would* do without doing it), echo `input.callID`, and return `.failure` with a human-readable message instead of throwing where the agent can recover.

## Permission Levels

Declared per tool via `permissionLevel` (`Sources/RuneWeaverCore/PermissionLevel.swift`). The permission gate enforces them; graduated trust lets users stop re-approving the same safe action.

| Level | Meaning | When to use it |
|-------|---------|----------------|
| `readOnly` | Always allowed. No approval needed. | Search, read, summarize, list, query state. Anything that cannot change the world (e.g. `email.search`, `files.read`, `clock.now`). Default for new tools unless you have a reason otherwise. |
| `requiresApproval` | Must be approved per-invocation, unless covered by a graduated-trust grant (allow this time / 5 min / 1 hour / 1 day / forever, scoped per action-type per target). | Anything that mutates state or talks to the outside world: sending email, writing files to the real filesystem, clicking submit in a browser, toggling a light. Prefer this for all writers. |
| `trusted` | Auto-approved per trust policy; single-user owner `remember_fact`/`recall_memories` are always `trusted`, run without approval prompts, and every memory write is audit-logged. | High-frequency, low-risk writes the user has explicitly blessed (e.g. appending to a daily log) plus owner memory writes. Rare except owner memory — needs a clear justification in review. |

Rules of thumb:

- When in doubt, pick `requiresApproval` for writes and `readOnly` for reads. Escalating later is easy; explaining an unapproved side effect is not.
- File writes stage in `~/.runeweaver/sandbox/` (`pending/` → `approved/`) before touching the real filesystem.
- Browser automation runs in an isolated Playwright context per task; submitting data or clicking real buttons always requires approval.
- Never put secrets in `description`, `inputSchema`, logs, or errors — inject them at execution time via `SecretsManager` / `ToolContext`.

## Testing Plugins

Each target has a suite under `Tests/<Target>Tests/` (e.g. `Tests/RuneWeaverToolsTests/ToolBusTests.swift` for tool dispatch). Follow the same pattern for new tools:

1. **Unit-test the handler** — construct a `ToolInput` with canned `argumentsJSON`, a `ToolContext(conversationID: UUID(), dryRun: true/false)`, and assert on `ToolOutput.content` / `isError` / `callID` echo.
2. **Test both dry-run and live paths** — `dryRun: true` must not mutate anything; assert no side effects.
3. **Test the schema contract** — feed malformed `argumentsJSON` and expect a clean `.failure`, not a crash.
4. **Test registration and dispatch** — register with a `ToolBus`, dispatch by `name`, and confirm routing plus permission-level metadata.
5. **Sandbox Python tools** — run the subprocess bridge locally, kill it mid-call, and confirm the Swift core survives; fuzz stdin/stdout framing.

```bash
swift test --filter RuneWeaverToolsTests   # tool dispatch + your new tool tests
swift test                                 # full suite
```

See `Plugins/README.md` for the short-form plugin cheat sheet and the on-disk layout (`~/.runeweaver/plugins/<name>/`).
