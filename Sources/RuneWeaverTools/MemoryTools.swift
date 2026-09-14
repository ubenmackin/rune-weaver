import Foundation
import RuneWeaverCore

/// Audit event recorded for every `remember_fact` write.
///
/// The audit trail is local-only (`~/.runeweaver/logs/memory-audit.jsonl`
/// by default): it carries the fact text, its category, the owning
/// conversation, and the stored fact identifier so later review can
/// reconstruct what the model asked to remember and when.
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
    /// - Parameters:
    ///   - toolName: Tool that performed the write.
    ///   - text: Stored fact text.
    ///   - category: Category recorded on the write. Defaults to nil.
    ///   - conversationID: Owning conversation identifier.
    ///   - factID: Stored fact identifier. Defaults to nil.
    ///   - timestamp: Record time. Defaults to now.
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
///
/// Injected by callers that need to observe writes (tests, CLI audit
/// views). When no handler is set the tool falls back to the local
/// JSONL file audit via ``FileMemoryAuditLog`` so every write is still
/// recorded. Dry runs never invoke the handler because no write occurs.
public typealias MemoryAuditHandler = @Sendable (MemoryAuditEvent) -> Void

/// Local JSONL audit log for memory writes.
///
/// Appends one JSON object per `remember_fact` write to
/// `~/.runeweaver/logs/memory-audit.jsonl` (overridable per call).
/// Writes are best-effort and serialized on a private queue: failures
/// are swallowed so auditing never fails the tool call.
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
    /// - Parameters:
    ///   - event: Audit event to record.
    ///   - fileURL: Destination file. Defaults to `defaultLogURL()`.
    public static func append(_ event: MemoryAuditEvent, to fileURL: URL? = nil) {
        guard let data = try? JSONEncoder().encode(event) else { return }
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
                // Best-effort: audit failures never fail the tool call.
            }
        }
    }
}

/// Arguments for the `remember_fact` tool.
///
/// Accepts the fact text under `text` (canonical) plus the `fact` and
/// `content` aliases so model-generated calls keep working when the
/// field name drifts. `category` is optional and recorded as the fact
/// source.
public struct RememberFactArgs: Sendable, Equatable, Decodable {
    /// Fact text to store.
    public let text: String
    /// Optional category recorded as the fact source.
    public let category: String?

    /// Memberwise initializer.
    /// - Parameters:
    ///   - text: Fact text to store.
    ///   - category: Optional category. Defaults to nil.
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
///
/// `limit` is optional and clamped to `1...50` (defaulting to `5`) so
/// recall never fans out an unbounded per-tier read.
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
    /// - Parameters:
    ///   - query: Free-text query.
    ///   - limit: Maximum results. Clamped to `1...50`.
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
///
/// Encoded as the `ToolOutput.content` JSON document so the model
/// receives the stored text, its category, identifier, and source
/// together.
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
    /// - Parameters:
    ///   - text: Stored fact text.
    ///   - category: Recorded category, if any.
    ///   - id: Stored fact identifier.
    ///   - source: Source recorded on the profile fact.
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
    /// - Parameters:
    ///   - content: Hit content.
    ///   - score: Relevance score.
    ///   - source: Originating tier.
    ///   - metadata: Key/value annotations. Defaults to empty.
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
///
/// Encoded as the `ToolOutput.content` JSON document so the model
/// receives the query, hit count, and ranked hits together.
public struct RecallMemoriesEnvelope: Sendable, Equatable, Codable {
    /// Query that was run.
    public let query: String
    /// Number of hits in `memories`.
    public let count: Int
    /// Hits, best first.
    public let memories: [MemoryHit]

    /// Creates a recall envelope.
    /// - Parameters:
    ///   - query: Query that was run.
    ///   - memories: Hits, best first.
    public init(query: String, memories: [MemoryHit]) {
        self.query = query
        self.memories = memories
        self.count = memories.count
    }
}

/// Pure JSON encoding for the memory tool output documents.
///
/// Mirrors `EmailBridgeParsing`: envelopes encode with sorted keys so
/// fixture tests can assert on stable output without a live store.
public enum MemoryToolEncoding {
    /// Encodes a remember envelope as the tool output document.
    /// - Parameter envelope: Envelope to encode.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeRememberEnvelope(_ envelope: RememberFactEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a recall envelope as the tool output document.
    /// - Parameter envelope: Envelope to encode.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeRecallEnvelope(_ envelope: RecallMemoriesEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// `remember_fact` tool: persists one fact to long-lived memory.
///
/// Stores `text` preferring a vector-backed row via
/// `MemoryEngine.storeSemantic` when an embedder is configured, falling
/// back to a keyword-only row via `MemoryEngine.storeProfileFact` on any
/// embedding or dimension failure so writes stay durable. Either path
/// mirrors the fact into the user profile so both `recall` and profile
/// display surface it. The optional `category` is recorded as the fact
/// source (defaulting to `"tool"`). Every successful write is
/// audit-logged via the injected handler or the local JSONL file;
/// `dryRun` previews without storing or auditing.
///
/// Always `trusted`: single-user owner memory writes are explicitly
/// blessed per the owner memory-write trust ruling, so the model can
/// remember without approval prompts while every write stays
/// audit-logged.
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
    ///
    /// Nil preserves the keyword-only path so existing call sites behave
    /// identically; when set, writes prefer a vector row and fall back to
    /// keyword-only on any embedding or dimension failure so embeddings
    /// never fail the write.
    private let embedder: (any EmbeddingsBackend)?

    /// Creates a remember tool.
    /// - Parameters:
    ///   - engine: Shared memory engine for profile and vector stores.
    ///   - audit: Audit sink for successful writes. Defaults to nil,
    ///     which appends to the local JSONL audit file.
    ///   - embedder: Optional embeddings producer for vector-backed writes.
    ///     Defaults to nil (keyword-only).
    public init(engine: MemoryEngine, audit: MemoryAuditHandler? = nil, embedder: (any EmbeddingsBackend)? = nil) {
        self.engine = engine
        self.audit = audit
        self.embedder = embedder
    }

    /// Stores the fact, audit-logging every write.
    /// - Parameters:
    ///   - input: Invocation with `text` and optional `category`.
    ///   - context: Ambient execution context.
    /// - Returns: JSON envelope with the stored fact, or a failure
    ///   without secrets.
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
    /// - Parameters:
    ///   - text: Stored fact text.
    ///   - category: Recorded category, if any.
    ///   - conversationID: Owning conversation identifier.
    ///   - factID: Stored fact identifier.
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
///
/// Recalls via `MemoryEngine.recall`, which merges episodic FTS hits,
/// semantic hits, and profile keyword hits best-first, so the model
/// recovers past turns and stored facts. When an embedder is configured
/// the query is embedded best-effort and semantic hits rank by cosine
/// similarity; otherwise (or on any embedding failure) semantic search
/// uses keyword overlap, so recall works with zero ML dependencies.
/// Read-only in effect: it never mutates stores and ignores `dryRun`.
///
/// Always `trusted`: owner memory reads are explicitly blessed per the
/// owner memory-write trust ruling alongside `remember_fact`, so the
/// model can recall without approval prompts.
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
    ///
    /// Nil preserves the keyword-only path so existing call sites behave
    /// identically; when set, the query is embedded best-effort and the
    /// vector ranks semantic hits by cosine similarity, falling back to
    /// nil (keyword overlap) on any embedding failure.
    private let embedder: (any EmbeddingsBackend)?

    /// Creates a recall tool.
    /// - Parameters:
    ///   - engine: Shared memory engine for episodic and profile stores.
    ///   - embedder: Optional embeddings producer for vector-ranked recall.
    ///     Defaults to nil (keyword-only).
    public init(engine: MemoryEngine, embedder: (any EmbeddingsBackend)? = nil) {
        self.engine = engine
        self.embedder = embedder
    }

    /// Searches memory and returns ranked hits.
    /// - Parameters:
    ///   - input: Invocation with `query` and optional `limit`.
    ///   - context: Ambient execution context.
    /// - Returns: JSON envelope with ranked memories, or a failure.
    /// - Throws: `CancellationError` when the enclosing task is cancelled; the
    ///   abort propagates instead of degrading to a tool failure.
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
        // Embed the query best-effort when a producer is configured: vector
        // hits then rank by cosine similarity while keyword tiers stay
        // unchanged, and any embedding failure keeps today's keyword path.
        // Cancellation propagates so a cancelled recall never degrades.
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
///
/// Both tools are `trusted` per the owner memory-write trust ruling so
/// chat runs them without approval prompts; `remember_fact` writes are
/// audit-logged. The shared `MemoryEngine` must be the same instance
/// the chat loop mirrors turns into so working, episodic, and profile
/// views stay consistent.
public enum MemoryTools {
    /// Tool names in registration order.
    public static let toolNames = ["remember_fact", "recall_memories"]

    /// Builds the memory tools for a shared engine.
    /// - Parameters:
    ///   - engine: Shared memory engine for profile and episodic stores.
    ///   - audit: Audit sink for `remember_fact` writes. Defaults to
    ///     nil (local JSONL file audit).
    ///   - embedder: Optional embeddings producer forwarded to both tools.
    ///     Defaults to nil (keyword-only).
    /// - Returns: Remember and recall tools in registration order.
    public static func makeTools(engine: MemoryEngine, audit: MemoryAuditHandler? = nil, embedder: (any EmbeddingsBackend)? = nil) -> [any Tool] {
        let remember: any Tool = RememberFactTool(engine: engine, audit: audit, embedder: embedder)
        let recall: any Tool = RecallMemoriesTool(engine: engine, embedder: embedder)
        return [remember, recall]
    }

    /// Registers the memory tools, replacing same-named entries.
    /// - Parameters:
    ///   - bus: Bus receiving the tools (surfaced via `status` and sent
    ///     to the model as tool definitions every chat turn).
    ///   - engine: Shared memory engine for profile and episodic stores.
    ///   - audit: Audit sink for `remember_fact` writes. Defaults to
    ///     nil (local JSONL file audit).
    ///   - embedder: Optional embeddings producer forwarded to both tools.
    ///     Defaults to nil (keyword-only).
    public static func register(on bus: ToolBus, engine: MemoryEngine, audit: MemoryAuditHandler? = nil, embedder: (any EmbeddingsBackend)? = nil) async {
        for tool in makeTools(engine: engine, audit: audit, embedder: embedder) {
            await bus.register(tool: tool)
        }
    }
}
