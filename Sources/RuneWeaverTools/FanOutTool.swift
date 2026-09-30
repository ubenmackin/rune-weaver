// Rune Weaver Tools — Autonomous fan-out tool for the shared ToolBus (`fanout.run`).
//
// Purpose: lets the calling agent spawn bounded parallel worker turns through
// the fan-out engine as one approval-gated call, so multi-step research runs
// concurrently instead of serially inside one turn. Scope: argument decoding,
// read-only subset derivation, and engine dispatch only; concurrency, run
// rows, and the merge pass live in FanOutEngine. Architectural role: the
// agent's lever for parallel autonomous work — the call itself parks for
// approval because it spends model rounds, workers get the read-only tool
// subset unless the fanout tool settings widen them to the full registry,
// and real-world actions still ride their own permission-gated tools so a
// worker swarm cannot mutate state by surprise.

import Foundation
import RuneWeaverCore

// MARK: - Arguments

/// Arguments for `fanout.run`.
public struct FanOutRunArgs: Sendable, Equatable, Decodable {
    /// Explicit subtasks the engine executes verbatim; decomposition belongs
    /// to the calling agent, never to the tool or the engine.
    public let subtasks: [FanOutSubtaskArgs]

    /// Creates run args.
    /// - Parameter subtasks: Explicit subtask list.
    public init(subtasks: [FanOutSubtaskArgs] = []) {
        self.subtasks = subtasks
    }

    private enum CodingKeys: String, CodingKey {
        case subtasks
    }

    /// Decodes run args, defaulting an absent list to empty so a caller that
    /// sent no subtasks still decodes and reads the honest rejection instead
    /// of a decode failure.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subtasks = try container.decodeIfPresent([FanOutSubtaskArgs].self, forKey: .subtasks) ?? []
    }
}

/// One subtask inside `fanout.run` arguments.
public struct FanOutSubtaskArgs: Sendable, Equatable, Decodable {
    /// Human-readable title for display and the audit trail.
    public let title: String
    /// Full prompt the worker turn runs.
    public let prompt: String

    /// Creates one subtask argument pair.
    /// - Parameters:
    ///   - title: Display title for the run rows.
    ///   - prompt: Full prompt the worker turn runs.
    public init(title: String, prompt: String) {
        self.title = title
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case prompt
    }

    /// Decodes one subtask argument pair.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
    }

    /// Trimmed title.
    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed prompt.
    var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Envelope

/// One subtask status in the `fanout.run` output envelope.
public struct FanOutSubtaskWire: Sendable, Equatable, Codable {
    /// Subtask title.
    public let title: String
    /// Lifecycle state after the run settled.
    public let status: String

    /// Creates one subtask status wire.
    /// - Parameters:
    ///   - title: Subtask title.
    ///   - status: Lifecycle state raw value.
    public init(title: String, status: String) {
        self.title = title
        self.status = status
    }
}

/// Envelope wrapping `fanout.run` output.
///
/// The merged summary rides the envelope so the calling agent renders one
/// honest digest in its own turn without re-reading the run rows; the origin
/// session link is claimed only when the conversation manager knows the
/// session, so unknown sessions never conjure ghost links.
public struct FanOutRunEnvelope: Sendable, Equatable, Codable {
    /// Created run identifier.
    public let runID: String
    /// Parent lifecycle state after every subtask settled.
    public let status: String
    /// Merged summary (reviewer output, or the fail-open fallback).
    public let summary: String?
    /// Per-subtask statuses, in run order.
    public let subtasks: [FanOutSubtaskWire]
    /// Session the run's parent row links back to, when the calling session
    /// was known to the conversation manager.
    public let sessionID: String?

    /// Creates a run envelope.
    /// - Parameters:
    ///   - runID: Created run identifier.
    ///   - status: Parent lifecycle state.
    ///   - summary: Merged summary, or nil while unwritten.
    ///   - subtasks: Per-subtask statuses.
    ///   - sessionID: Linked origin session, when known.
    public init(
        runID: String,
        status: String,
        summary: String? = nil,
        subtasks: [FanOutSubtaskWire] = [],
        sessionID: String? = nil
    ) {
        self.runID = runID
        self.status = status
        self.summary = summary
        self.subtasks = subtasks
        self.sessionID = sessionID
    }
}

/// Pure JSON encoding for the fan-out tool output document.
public enum FanOutToolEncoding {
    /// Encodes any fan-out envelope as the tool output document.
    /// - Parameter envelope: Envelope to encode.
    /// - Returns: The JSON document text.
    public static func encode(_ envelope: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Tool

/// `fanout.run` tool: spawns bounded parallel worker turns through the
/// fan-out engine.
public struct FanOutTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and scheduler prompts.
    public let name = "fanout.run"
    /// When the LLM should use this tool.
    ///
    /// The description teaches the model the worker bargain up front so it
    /// plans subtasks knowing what its workers can and cannot do: the
    /// read-only subset unless the fanout tool settings widen it to the full
    /// registry, and real-world actions still ride their own permission-gated
    /// tools.
    public let description =
        "Spawns parallel worker subagents that run their own subtask prompts concurrently and returns one merged summary. "
            + "Use when independent research or investigation steps can run at the same time. "
            + "Workers get the read-only tool subset unless the fanout tool settings widen them to the full registry; "
            + "real-world actions still ride their own permission-gated tools, so a worker cannot mutate state without approval. "
            + "Pass explicit subtasks; the engine executes the list it is handed and never decomposes for you."
    /// Function-calling contract for the explicit subtask list.
    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"#
            + #""subtasks":{"type":"array","description":"Explicit subtasks to run concurrently","#
            + #""maxItems":8,"items":{"type":"object","properties":{"#
            + #""title":{"type":"string","description":"Short human-readable subtask title"},"#
            + #""prompt":{"type":"string","description":"Full prompt the worker turn runs"}},"#
            + #""required":["title","prompt"],"additionalProperties":false}}},"#
            + #""required":["subtasks"],"additionalProperties":false}"#
    )
    /// Spawning autonomous work spends concurrent model rounds, so every call
    /// parks for approval — the same bargain as the scheduler job's own runs.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Fan-out engine running the swarm.
    private let engine: FanOutEngine
    /// Sessions owner verifying the origin link; nil keeps the tool usable
    /// without a manager (the envelope then never claims a session link).
    private let conversations: ConversationManager?
    /// Read-only tool names the workers get unless the fanout tool settings
    /// widen workers to the full registry, derived once at registration from
    /// the built registry snapshot so the subset stays deterministic; names for tools
    /// disabled on the bus simply filter to nothing in the orchestrator's
    /// enabled-only snapshot, so they are harmless to carry.
    private let allowedToolNames: [String]

    /// Creates a fan-out tool.
    /// - Parameters:
    ///   - engine: Fan-out engine running the swarm.
    ///   - conversations: Sessions owner for the origin-link verification.
    ///   - allowedToolNames: Read-only tool names workers may call.
    public init(engine: FanOutEngine, conversations: ConversationManager? = nil, allowedToolNames: [String] = []) {
        self.engine = engine
        self.conversations = conversations
        self.allowedToolNames = allowedToolNames
    }

    /// Spawns the run, links the calling session as the parent, and returns
    /// the settled envelope.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: FanOutRunArgs
        do {
            args = try JSONDecoder().decode(FanOutRunArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid fanout.run arguments: expected {\"subtasks\": [{\"title\": \"<short>\", \"prompt\": \"<full prompt>\"}]}.",
                callID: input.callID
            )
        }
        guard !args.subtasks.isEmpty else {
            return .failure("Invalid fanout.run arguments: 'subtasks' must not be empty.", callID: input.callID)
        }
        if args.subtasks.contains(where: { $0.trimmedTitle.isEmpty || $0.trimmedPrompt.isEmpty }) {
            return .failure(
                "Invalid fanout.run arguments: each subtask requires a non-empty 'title' and 'prompt'.",
                callID: input.callID
            )
        }
        // Workers get the read-only subset unless the fanout tool settings
        // widen them to the full registry, so research fan-out cannot mutate state.
        let fullTools = await engine.fullTools
        let allowedTools = fullTools ? nil : allowedToolNames
        if context.dryRun {
            return .success("Dry run: would fan out \(args.subtasks.count) subtask(s).", callID: input.callID)
        }
        do {
            // The engine settles the whole swarm (workers, merge pass, and
            // run rows) before returning, so the envelope carries the honest
            // merged summary instead of a premature in-flight snapshot.
            let run = try await engine.runFanOut(
                subtasks: args.subtasks.map { FanOutSubtask(title: $0.trimmedTitle, prompt: $0.trimmedPrompt) },
                originSessionID: context.conversationID,
                allowedTools: allowedTools
            )
            // The origin session links the swarm's parent row back to the turn
            // that asked for it. The link is claimed in the output only when
            // the conversation manager knows the session, mirroring the goal
            // creation pattern — unknown sessions never conjure ghost links.
            var linkedSessionID: String?
            if let conversations, await conversations.session(id: context.conversationID) != nil {
                linkedSessionID = context.conversationID.uuidString
            }
            let envelope = FanOutRunEnvelope(
                runID: run.id.uuidString,
                status: run.status.rawValue,
                summary: run.summary,
                subtasks: run.subtasks.map { FanOutSubtaskWire(title: $0.title, status: $0.status.rawValue) },
                sessionID: linkedSessionID
            )
            let content = try FanOutToolEncoding.encode(envelope)
            return .success(content, callID: input.callID)
        } catch let error as FanOutError {
            return .failure(Self.failureMessage(for: error), callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure("Could not run fan-out: \(error.localizedDescription)", callID: input.callID)
        }
    }

    /// Maps one typed engine rejection onto honest tool copy.
    /// The typed cases are the caller's only error surface, so each reads as
    /// its own guidance instead of a generic engine failure.
    /// - Parameter error: The error the engine threw.
    /// - Returns: The honest failure copy.
    static func failureMessage(for error: FanOutError) -> String {
        switch error {
        case let .maxWorkersReached(limit):
            "Fan-out subtask list exceeds the configured worker cap of \(limit). Reduce the subtask count or raise [fanout] max_workers."
        case .emptySubtasks:
            "Fan-out requires at least one subtask with a title and prompt."
        }
    }
}

// MARK: - Factory

/// Factory registering the LLM-invokable fan-out tool on a `ToolBus`.
public enum FanOutTools {
    /// Tool names in registration order.
    public static let toolNames = ["fanout.run"]

    /// Builds the fan-out tool for a shared engine.
    ///
    /// The tool builds whenever an engine arrives; enablement lives solely in
    /// the tool-state toggle — the tool ships disabled (see
    /// `BuiltinToolPlugins.shipsDisabledToolNames`) and an operator enable is
    /// the only gate before it runs, keeping `GET /tools` stable instead of
    /// shape-shifting with config. Session-link verification rides the optional
    /// conversations manager; nil keeps the envelope's session link off so
    /// engine-only callers still work.
    /// - Parameters:
    ///   - engine: Fan-out engine running the swarm.
    ///   - conversations: Sessions owner for the origin-link verification.
    ///   - allowedToolNames: Read-only tool names workers may call.
    /// - Returns: Tools in registration order.
    public static func makeTools(
        engine: FanOutEngine,
        conversations: ConversationManager? = nil,
        allowedToolNames: [String] = []
    ) -> [any Tool] {
        [FanOutTool(engine: engine, conversations: conversations, allowedToolNames: allowedToolNames)]
    }
}
