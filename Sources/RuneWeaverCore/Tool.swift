/// A capability plugin the agent can invoke.
///
/// Each tool is a self-contained module that declares its identity
/// (`name`, `description`), its function-calling contract
/// (`inputSchema`), its trust requirement (`permissionLevel`), and
/// its handler (`execute(input:context:)`).
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
    /// - Parameters:
    ///   - input: Invocation arguments.
    ///   - context: Ambient execution context.
    /// - Returns: The tool result.
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput
}
