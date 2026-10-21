# Plugin Developer Guide ("Runes")

Capabilities are plugins. A plugin ("rune") is a self-contained module that gives the agent hands in the world: search email, click a web page, toggle a light, or run code. Add new ones without touching the core.

There are two flavors:

- **Swift plugins**: conform to `RuneWeaverCore.Tool`, register with `ToolBus`. Native speed, type safety, direct Apple framework access.
- **Python plugins**: for Playwright, email parsing, and anything where the ML/integration ecosystem is Python-first (Whisper runs as a local CLI binary instead). They run in a sandboxed subprocess and talk JSON-RPC over stdin/stdout, so a bad Python plugin can't crash the Swift core.

## The `Tool` Protocol

Every Swift tool conforms to `RuneWeaverCore.Tool` (`Sources/RuneWeaverCore/Tool.swift`):

```swift
public protocol Tool: Sendable {
    var name: String { get }                         // e.g. "email.search"
    var description: String { get }                  // when the LLM should use it
    var inputSchema: JSONSchema { get }              // function-calling contract
    var permissionLevel: PermissionLevel { get }      // trust requirement (.readOnly, .requiresApproval, .trusted)
    var contentTrustLevel: ContentTrustLevel { get } // provenance (.trusted or .untrustedExternal)
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput
}
```

The protocol extension provides a default `contentTrustLevel` of `.trusted`. Any tool returning external or network-derived data (such as web search, page fetch, or external API responses) should declare `.untrustedExternal` so that `[security].untrusted_labeling` wraps the output in data-only delimiters, preventing prompt injection attacks.

Supporting types (`Sources/RuneWeaverCore/ToolContext.swift`, `ToolOutput.swift`, `Tool.swift`):

- `JSONSchema`: wraps the raw JSON Schema document (`rawValue: String`) describing the input arguments. Use `.emptyObject` (`{"type":"object"}`) for argument-free tools.
- `ToolInput`: `toolName`, `argumentsJSON` (raw JSON matching your schema), `callID` (correlation ID, defaults to a UUID).
- `ToolContext`: execution context provided to the handler:
  - `conversationID` / `sessionID`: UUID of the owning session.
  - `dryRun: Bool`: when `true`, the tool must not mutate external state (return a preview of what *would* happen).
  - `approved: Bool`: when `true`, an explicit approval decision from the permission gate authorizes the mutating branch to run.
  - `progress: ToolProgressReporter`: an async callback `(ToolProgress) async -> Void` for reporting live progress.
- `ToolOutput`: `content`, `isError`, `callID`, and optional `errorKind: ToolErrorKind?` (e.g. `.invalidSyntax`, `.executionError`). Use `.success(_:callID:)` / `.failure(_:callID:errorKind:)` conveniences. Always echo back `input.callID`.

Registration: create your tool and call `ToolBus.register(tool: Tool, isEnabled: Bool = true)`. Installed external plugin checkouts live under `~/.runeweaver/plugins/<name>/`.

## Minimal Example

A read-only clock tool: small enough to copy-paste, complete enough to show every piece:

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
await bus.register(tool: ClockTool())
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

- `name`: stable, dotted, lowercase (`domain.verb`: `email.search`, `files.read`). Never rename once shipped; the LLM and memory reference it.
- `description`: write for the LLM: say **when** to use the tool and what it returns, not how it works.
- `inputSchema`: keep it tight. Every required field is a chance for the model to hallucinate; prefer few required fields with clear types.
- `execute`: honor `context.dryRun` (return what you *would* do without doing it), echo `input.callID`, and return `.failure` with an appropriate `ToolErrorKind` instead of throwing where the agent can recover.

## Progress Reporting

Long-running tools (scans, searches, downloads, batch operations) can emit indeterminate progress frames to the dashboard and clients:

```swift
await context.progress(ToolProgress(
    message: "Scanning directory",
    scanned: 42,
    matched: 3,
    elapsedMs: 350,
    current: "Sources/App.swift" // relative display path only; never use absolute paths
))
```

- Progress is advisory and throttled: emitters keep a 500 ms time floor (`ToolProgress.minimumReportIntervalNanoseconds`) between updates.
- `current` must always be a safe relative path: absolute roots or traversing (`..`) paths are automatically stripped.
- The `callID` and `toolName` are stamped authoritatively by `ToolBus`.

## Permission Levels

Declared per tool via `permissionLevel` (`Sources/RuneWeaverCore/PermissionLevel.swift`). The permission gate enforces them; graduated trust lets users stop re-approving the same safe action.

| Level | Meaning | When to use it |
|-------|---------|----------------|
| `readOnly` | Always allowed. No approval needed. | Search, read, summarize, list, query state. Anything that cannot change the world (e.g. `email.search`, `files.read`, `clock.now`). Default for new tools unless you have a reason otherwise. |
| `requiresApproval` | Must be approved per-invocation, unless covered by a graduated-trust grant (allow this time / 5 min / 1 hour / 1 day / forever, scoped per action-type per target). | Anything that mutates state or talks to the outside world: sending email, writing files, clicking submit in a browser, running shell commands. Prefer this for all writers. |
| `trusted` | Auto-approved per trust policy; single-user owner `memories.store`/`memories.recall` are always `trusted`, run without approval prompts, and every memory write is audit-logged. | High-frequency, low-risk writes explicitly blessed by policy plus owner memory writes. Rare except owner memory. |

Rules of thumb:

- When in doubt, pick `requiresApproval` for writes and `readOnly` for reads. Escalating later is easy; explaining an unapproved side effect is not.
- Gated tools check `context.approved`: when `false`, they return a dry-run preview or park for approval; when `true`, they execute the mutation.
- File writes integrate with the `[files].write_mode` setting:
  - `staged` (default for file write tools): mutations persist to `StagedFilesStore` and render as inline DiffCards in the Staged Changes drawer for interactive review (`live-accept` / `live-decline`).
  - `live`: mutations write directly to disk with an automatic `.rune_backup_<UUID>` rollback snapshot.
- Browser automation runs in an isolated Playwright context per task; submitting forms or clicking buttons requires approval.
- Never put secrets in `description`, `inputSchema`, logs, or errors: inject them at execution time via `SecretsManager` / `ToolContext`.

## Disabled-by-Default Tools

Sensitive or resource-intensive capabilities (such as `desktop.screenshot`, `desktop.action`, and `fanout.run`) follow the **single-gate enablement rule**:
- They register with `isEnabled: false` at startup (`BuiltinToolPlugins.shipsDisabledToolNames`).
- The persistent `ToolStateStore` (`GET /tools` and `PATCH /tools/:id/state`) is the sole authority for whether they are exposed to the model.

## Testing Plugins

Each target has a suite under `Tests/<Target>Tests/` (e.g. `Tests/RuneWeaverToolsTests/ToolBusTests.swift` for tool dispatch). Follow the same pattern for new tools:

1. **Unit-test the handler**: construct a `ToolInput` with canned `argumentsJSON`, a `ToolContext(conversationID: UUID(), dryRun: true/false, approved: true/false)`, and assert on `ToolOutput.content` / `isError` / `callID` echo.
2. **Test both dry-run and live paths**: `dryRun: true` must not mutate anything; assert no side effects. Test `approved: true` vs `approved: false`.
3. **Test the schema contract**: feed malformed `argumentsJSON` and expect a clean `.failure(..., errorKind: .invalidSyntax)`, not a crash.
4. **Test registration and dispatch**: register with a `ToolBus`, dispatch by `name`, and confirm routing plus permission-level metadata.
5. **Sandbox Python tools**: run the subprocess bridge locally, kill it mid-call, and confirm the Swift core survives; fuzz stdin/stdout framing.

```bash
swift test --filter RuneWeaverToolsTests   # tool dispatch + your new tool tests
swift test                                 # full suite
```

See `Plugins/README.md` for the short-form plugin cheat sheet and the on-disk layout (`~/.runeweaver/plugins/<name>/`).
