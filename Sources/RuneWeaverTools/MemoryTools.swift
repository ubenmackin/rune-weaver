// Rune Weaver Tools — Long-term memory plugin tools for recall and persistence.

import Foundation
import RuneWeaverCore

/// Audit event recorded for every `remember_fact` write.
public struct MemoryAuditEvent: Sendable, Codable, Equatable {
    /// Name of the tool that performed the write (`remember_fact`).
    public let toolName: String
    /// Stored fact text (trimmed).
    public let text: String
    /// Category recorded on the write, if the caller supplied one.
    public let category: String?
    /// Owning conversation identifier.
    public let conversationID: String
    /// Stored fact identifier, when the write succeeded.
    public let factID: String?
    /// When the write was recorded.
    public let timestamp: Date

    /// Creates an audit event.
    public init(
        toolName: String,
        text: String,
        category: String? = nil,
        conversationID: String,
        factID: String? = nil,
        timestamp: Date = Date()
    ) {
        self.toolName = toolName
        self.text = text
        self.category = category
        self.conversationID = conversationID
        self.factID = factID
        self.timestamp = timestamp
    }
}

/// Audit sink invoked for every `remember_fact` write.
public typealias MemoryAuditHandler = @Sendable (MemoryAuditEvent) -> Void

/// Local JSONL audit log for memory writes.
public enum FileMemoryAuditLog {
    /// Serial queue ordering audit appends.
    private static let queue = DispatchQueue(label: "com.runeweaver.memory.audit", qos: .utility)

    /// Default audit file URL.
    /// - Returns: `~/.runeweaver/logs/memory-audit.jsonl` as a file URL.
    public static func defaultLogURL() -> URL {
        let expanded = ("~/.runeweaver/logs" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).appendingPathComponent("memory-audit.jsonl")
    }

    /// Appends an event as one JSON line, best-effort.
    public static func append(_ event: MemoryAuditEvent, to fileURL: URL? = nil) {
        let data: Data
        do {
            data = try JSONEncoder().encode(event)
        } catch {
            RuneWeaverLog.tools.error("FileMemoryAuditLog: failed to encode MemoryAuditEvent: \(error.localizedDescription)")
            return
        }
        var line = data
        line.append(0x0A)
        let url = fileURL ?? defaultLogURL()
        let payload = line
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payload)
                } else {
                    try payload.write(to: url, options: .atomic)
                }
            } catch {
                RuneWeaverLog.tools.warning("FileMemoryAuditLog: Failed to append memory audit record to \(url.path): \(error)")
                // Best-effort: audit failures never fail the tool call.
            }
        }
    }
}

/// Arguments for the `remember_fact` tool.
public struct RememberFactArgs: Sendable, Equatable, Decodable {
    /// Fact text to store.
    public let text: String
    /// Optional category recorded as the fact source.
    public let category: String?

    /// Memberwise initializer.
    public init(text: String, category: String? = nil) {
        self.text = text
        self.category = category
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case fact
        case content
        case category
    }

    /// Decodes arguments, accepting every documented text alias.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .text), !direct.isEmpty {
            text = direct
        } else if let alias = try container.decodeIfPresent(String.self, forKey: .fact), !alias.isEmpty {
            text = alias
        } else if let content = try container.decodeIfPresent(String.self, forKey: .content), !content.isEmpty {
            text = content
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.text,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing fact text (expected 'text', 'fact', or 'content')"
                )
            )
        }
        category = try container.decodeIfPresent(String.self, forKey: .category)
    }

    /// Trimmed fact text.
    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed category, nil when absent or blank.
    public var trimmedCategory: String? {
        guard let category else { return nil }
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Arguments for the `recall_memories` tool.
public struct RecallMemoriesArgs: Sendable, Equatable, Decodable {
    /// Free-text query matched against episodic and profile memory.
    public let query: String
    /// Maximum results to return, clamped to `1...50`.
    public let limit: Int

    /// Default hit count when the caller omits `limit`.
    public static let defaultLimit = 5
    /// Upper bound for `limit` so recall stays bounded.
    public static let maxLimit = 50

    /// Memberwise initializer with limit clamping.
    public init(query: String, limit: Int = defaultLimit) {
        self.query = query
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case limit
    }

    /// Decodes arguments, clamping `limit`.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedQuery = try container.decode(String.self, forKey: .query)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.init(query: decodedQuery, limit: rawLimit)
    }

    /// Trimmed query text.
    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Envelope wrapping `remember_fact` tool output.
public struct RememberFactEnvelope: Sendable, Equatable, Codable {
    /// Stored fact text (trimmed).
    public let text: String
    /// Category recorded on the write, if any.
    public let category: String?
    /// Stored fact identifier.
    public let id: String
    /// Source recorded on the profile fact.
    public let source: String

    /// Creates a remember envelope.
    public init(text: String, category: String?, id: String, source: String) {
        self.text = text
        self.category = category
        self.id = id
        self.source = source
    }
}

/// One `recall_memories` hit: content plus its tier and score.
public struct MemoryHit: Sendable, Equatable, Codable {
    /// Human-readable content.
    public let content: String
    /// Relevance score (higher is more relevant).
    public let score: Double
    /// Memory tier that produced this hit (`episodic`, `semantic`, `profile`).
    public let source: String
    /// Key/value annotations (session id, fact id, role, ...).
    public let metadata: [String: String]

    /// Creates a memory hit.
    public init(content: String, score: Double, source: String, metadata: [String: String] = [:]) {
        self.content = content
        self.score = score
        self.source = source
        self.metadata = metadata
    }

    /// Creates a hit from a `MemoryResult`.
    /// - Parameter result: Engine recall hit.
    /// - Returns: Equivalent wire hit.
    public init(_ result: MemoryResult) {
        self.content = result.content
        self.score = result.score
        self.source = result.source.rawValue
        self.metadata = result.metadata
    }
}

/// Envelope wrapping `recall_memories` tool output.
public struct RecallMemoriesEnvelope: Sendable, Equatable, Codable {
    /// Query that was run.
    public let query: String
    /// Number of hits in `memories`.
    public let count: Int
    /// Hits, best first.
    public let memories: [MemoryHit]

    /// Creates a recall envelope.
    public init(query: String, memories: [MemoryHit]) {
        self.query = query
        self.memories = memories
        self.count = memories.count
    }
}

/// Pure JSON encoding for the memory tool output documents.
public enum MemoryToolEncoding {
    /// Encodes a remember envelope as the tool output document.
    public static func encodeRememberEnvelope(_ envelope: RememberFactEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a recall envelope as the tool output document.
    public static func encodeRecallEnvelope(_ envelope: RecallMemoriesEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// `remember_fact` tool: persists one fact to long-lived memory.
public struct RememberFactTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "remember_fact"
    /// When the LLM should use this tool.
    public let description =
        "Remembers one fact about the user for later. "
            + "Use when the user asks to remember something or states a durable preference or fact. "
            + "Returns the stored fact id and source."
    /// Function-calling contract for `text` and optional `category`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"text":{"type":"string","description":"Fact text to remember "#
                + #"(e.g. my dog is named Biscuit)"},"category":{"type":"string","description":"Optional category "#
                + #"recorded as the fact source (e.g. preference, contact)"}},"required":["text"],"additionalProperties":false}"#
        )
    /// Auto-allowed per the owner memory-write trust ruling; no approval prompts.
    public let permissionLevel = PermissionLevel.trusted

    /// Shared memory engine receiving the fact.
    private let engine: MemoryEngine
    /// Audit sink for successful writes. Defaults to nil (file audit).
    private let audit: MemoryAuditHandler?
    /// Optional embeddings producer for vector-backed writes.
    private let embedder: (any EmbeddingsBackend)?

    /// Creates a remember tool.
    public init(engine: MemoryEngine, audit: MemoryAuditHandler? = nil, embedder: (any EmbeddingsBackend)? = nil) {
        self.engine = engine
        self.audit = audit
        self.embedder = embedder
    }

    /// Stores the fact, audit-logging every write.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: RememberFactArgs
        do {
            args = try JSONDecoder().decode(RememberFactArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid remember_fact arguments: expected {\"text\": \"<fact>\", \"category\": \"<optional>\"}.", callID: input.callID)
        }
        let text = args.trimmedText
        guard !text.isEmpty else {
            return .failure("Invalid remember_fact arguments: 'text' must not be empty.", callID: input.callID)
        }
        guard MemoryEngine.isStorableFact(text) else {
            return .failure("Invalid remember_fact arguments: 'text' must contain alphanumeric characters.", callID: input.callID)
        }
        let category = args.trimmedCategory
        let source = category ?? "tool"
        if context.dryRun {
            return .success("Dry run: would remember '\(text)' (category: \(category ?? "none")).", callID: input.callID)
        }
        // Vector-backed writes share the engine helper with the server facts
        // route so embedding, fallback, and cancellation stay single-sourced;
        // cancellation propagates while other failures surface as tool errors.
        do {
            let fact = try await engine.storeFactWithEmbedder(content: text, source: source, embedder: embedder)
            let envelope = RememberFactEnvelope(text: fact.content, category: category, id: fact.id.uuidString, source: fact.source)
            let content = try MemoryToolEncoding.encodeRememberEnvelope(envelope)
            recordAudit(text: fact.content, category: category, conversationID: context.conversationID, factID: fact.id.uuidString)
            return .success(content, callID: input.callID)
        } catch let error as CancellationError {
            // Bound rethrow preserves the original cancellation error so the
            // turn aborts instead of surfacing as a tool failure.
            throw error
        } catch {
            return .failure("Could not remember that: \(error.localizedDescription)", callID: input.callID)
        }
    }

    /// Records one successful write to the audit sink or file.
    private func recordAudit(text: String, category: String?, conversationID: UUID, factID: String) {
        let event = MemoryAuditEvent(
            toolName: name,
            text: text,
            category: category,
            conversationID: conversationID.uuidString,
            factID: factID
        )
        if let audit {
            audit(event)
        } else {
            FileMemoryAuditLog.append(event)
        }
    }
}

/// `recall_memories` tool: searches episodic, semantic, and profile memory.
public struct RecallMemoriesTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "recall_memories"
    /// When the LLM should use this tool.
    public let description =
        "Recalls what is known about a topic from past conversations and stored facts. "
            + "Use when the user asks what you remember or references earlier context. "
            + "Returns ranked memories best first."
    /// Function-calling contract for `query` and `limit`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"query":{"type":"string","description":"Free-text query "#
                + #"matched against past turns and stored facts"},"limit":{"type":"integer","description":"Maximum "#
                + #"memories (1-50, default 5)","minimum":1,"maximum":50}},"required":["query"],"additionalProperties":false}"#
        )
    /// Auto-allowed per the owner memory-write trust ruling; no approval prompts.
    public let permissionLevel = PermissionLevel.trusted

    /// Shared memory engine serving recall.
    private let engine: MemoryEngine
    /// Optional embeddings producer for vector-ranked recall.
    private let embedder: (any EmbeddingsBackend)?

    /// Creates a recall tool.
    public init(engine: MemoryEngine, embedder: (any EmbeddingsBackend)? = nil) {
        self.engine = engine
        self.embedder = embedder
    }

    /// Searches memory and returns ranked hits.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: RecallMemoriesArgs
        do {
            args = try JSONDecoder().decode(RecallMemoriesArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid recall_memories arguments: expected {\"query\": \"<text>\", \"limit\": <1-50>}.", callID: input.callID)
        }
        let query = args.trimmedQuery
        guard !query.isEmpty else {
            return .failure("Invalid recall_memories arguments: 'query' must not be empty.", callID: input.callID)
        }
        // Embed the query best-effort when a producer is configured: vector hits then rank by
        // cosine similarity while keyword tiers stay unchanged, and any embedding failure keeps
        // today's keyword path. Cancellation propagates so a cancelled recall never degrades.
        let embedding: [Float]? = if let embedder {
            try await embedder.embedQuery(query)
        } else {
            nil
        }
        do {
            let results = try await engine.recall(query: query, embedding: embedding, limit: args.limit)
            let hits = results.map(MemoryHit.init)
            let content = try MemoryToolEncoding.encodeRecallEnvelope(RecallMemoriesEnvelope(query: query, memories: hits))
            return .success(content, callID: input.callID)
        } catch let error as CancellationError {
            // Bound rethrow preserves the original cancellation error so a
            // cancelled recall never disguises itself as a tool failure.
            throw error
        } catch {
            return .failure("Could not recall memories: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

/// Factory registering the LLM-invokable memory tools on a `ToolBus`.
public enum MemoryTools {
    /// Tool names in registration order.
    public static let toolNames = ["remember_fact", "recall_memories"]

    /// Builds the memory tools for a shared engine.
    public static func makeTools(engine: MemoryEngine, audit: MemoryAuditHandler? = nil, embedder: (any EmbeddingsBackend)? = nil) -> [any Tool] {
        let remember: any Tool = RememberFactTool(engine: engine, audit: audit, embedder: embedder)
        let recall: any Tool = RecallMemoriesTool(engine: engine, embedder: embedder)
        return [remember, recall]
    }

    /// Registers the memory tools, replacing same-named entries.
    public static func register(on bus: ToolBus, engine: MemoryEngine, audit: MemoryAuditHandler? = nil, embedder: (any EmbeddingsBackend)? = nil) async {
        for tool in makeTools(engine: engine, audit: audit, embedder: embedder) {
            await bus.register(tool: tool)
        }
    }
}
