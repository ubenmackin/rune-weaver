// Rune Weaver Core — Tool capability protocol and invocation interface.

/// A capability plugin the agent can invoke.
public protocol Tool: Sendable {
    /// Stable machine-readable identifier (e.g. `"email.search"`).
    var name: String { get }
    /// Human- and LLM-readable summary of when to use this tool.
    var description: String { get }
    /// JSON Schema describing the expected input arguments.
    var inputSchema: JSONSchema { get }
    /// Trust level enforced by the permission gate.
    var permissionLevel: PermissionLevel { get }

    /// Runs the tool.
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput
}
