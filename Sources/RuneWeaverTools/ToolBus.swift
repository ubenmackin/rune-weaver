import RuneWeaverCore

// Built-in tool plugins live in this module; the bus itself does not.
//
// `ToolBus`, `ToolResult`, and the permission gate are owned by
// `RuneWeaverCore` as the single source of truth. This module re-exports
// the core bus surface (via `RuneWeaverCore`) instead of defining a
// duplicate actor, so every caller — plugins, orchestrator, and CLI —
// shares one registry, one permission check, and one API
// (`register(tool:)` / `execute(toolCall:context:)` /
// `toolNames()` / `availableTools()`).
//
// To register a plugin tool, create a `RuneWeaverCore.Tool` and call
// `await bus.register(tool:)` on the shared `RuneWeaverCore.ToolBus`.
