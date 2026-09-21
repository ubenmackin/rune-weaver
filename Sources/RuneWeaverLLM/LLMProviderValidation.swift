// Rune Weaver LLM — Tool schema validation and request body builders for OpenAI-compatible endpoints.

import Foundation
import RuneWeaverCore

/// Validated tool definitions after wire schema filtering.
/// Groups wire-safe definitions with skipped names so one corrupt plugin degrades to fewer tools.
struct ValidatedDefinitions: Sendable {
    /// Definitions safe to send on the wire.
    let valid: [ToolDefinition]
    /// Names omitted for invalid schemas, carrying only names plus static reasons at call sites.
    let skipped: [String]
}

/// Checks whether a decoded schema object is safe to send on the wire.
/// Single-sources the rule through the prompt filter so wire and prompt agree
/// on which schemas are valid; strict backends reject non-object types and
/// malformed additionalProperties, so those degrade to fewer tools.
func isValidToolParametersObject(_ object: [String: Any]) -> Bool {
    VisionSchemaFilter.isValidParametersObject(object)
}

/// Decodes a tool's JSON Schema to a JSON object for request encoding.
func encodeToolParameters(_ tool: ToolDefinition) throws -> [String: Any] {
    guard let data = tool.parameters.rawValue.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          let object = parsed as? [String: Any]
    else {
        throw LLMProviderError.invalidResponse(
            "Tool '\(tool.name)' has an invalid JSON Schema; expected a JSON object"
        )
    }
    // Reject schemas that strict backends would refuse, keeping single-tool
    // callers loud while bulk request builders skip and continue text-only.
    guard isValidToolParametersObject(object) else {
        throw LLMProviderError.invalidResponse(
            "Tool '\(tool.name)' has an invalid JSON Schema; expected type object with valid additionalProperties"
        )
    }
    return object
}

/// Partitions definitions into wire-safe entries plus skipped names.
/// One corrupt plugin must not fail the whole turn, so invalid entries are
/// withheld with their tool name while valid tools still reach the model.
func validatedDefinitions(_ tools: [ToolDefinition], logSkips: Bool = true) -> ValidatedDefinitions {
    // Single-source the parse plus validity plus wording through the prompt
    // filter so prompt and wire withhold the same schemas with one message.
    let part = VisionSchemaFilter.partitionValidSchemas(
        entries: tools,
        name: { $0.name },
        rawSchema: { $0.parameters.rawValue },
        logSkips: logSkips
    )
    return ValidatedDefinitions(valid: part.valid, skipped: part.skipped)
}

/// Builds a JSON request body for `/chat/completions`.
/// - Parameters:
///   - cachePrompt: llama.cpp-only KV-cache hint; nil omits the key so cloud providers are unaffected.
///   - slotID: llama.cpp-only sticky slot; nil omits the key so the server auto-assigns.
func openAIChatRequestBody(
    model: String,
    messages: [Message],
    tools: [ToolDefinition],
    stream: Bool,
    cachePrompt: Bool? = nil,
    slotID: Int? = nil
) throws -> Data {
    // OpenAI-compatible endpoints reject an assistant `tool_calls` entry that no
    // following tool-role message answers. Parked/approval-gated placeholders persist
    // an assistant note with no results until the approval resumes, so restrict
    // promotion to call IDs that already have a result in this request.
    let answeredCallIDs = answeredToolCallIDs(in: messages)
    // Track identifiers across the whole request so a call ID re-persisted in a
    // later note cannot reach the wire twice beside its single answer.
    var emittedCallIDs = Set<String>()
    var wireMessages: [[String: Any]] = []
    wireMessages.reserveCapacity(messages.count)
    for message in messages {
        var entry: [String: Any] = [
            "role": OpenAIWireRole.string(for: message.role),
            "content": message.content
        ]
        if let callID = message.toolCallID {
            entry["tool_call_id"] = callID
        }
        if message.role == .assistant {
            let split = splitResponsesAssistantContent(
                message.content,
                answeredCallIDs: answeredCallIDs,
                excludingCallIDs: emittedCallIDs
            )
            if !split.toolCalls.isEmpty {
                emittedCallIDs.formUnion(split.toolCalls.map(\.id))
                entry["tool_calls"] = split.toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": sanitizedToolCallArgumentsJSON(call.argumentsJSON)
                        ]
                    ]
                }
            }
            // Plumbing notes carry only their leftover prose, so a scrubbed
            // dangling line or an excluded twin collapses to empty instead of
            // leaking `Calling …` upstream as request content.
            if split.recognizedPlumbing {
                entry["content"] = split.leftover
            }
        }
        wireMessages.append(entry)
    }
    if wireMessages.isEmpty {
        wireMessages = [["role": "user", "content": ""]]
    }
    var body: [String: Any] = [
        "model": model,
        "messages": wireMessages,
        "stream": stream
    ]
    if stream {
        body["stream_options"] = ["include_usage": true]
    }
    // llama.cpp-only prefix hints live behind explicit optionals so cloud wires
    // never see them; absent values omit the keys and preserve current behavior.
    if let cachePrompt {
        body["cache_prompt"] = cachePrompt
    }
    if let slotID {
        body["id_slot"] = slotID
    }
    if !tools.isEmpty {
        // Omit invalid entries so a single bad schema degrades to fewer tools, not a failed turn.
        let filtered = validatedDefinitions(tools)
        // Canonical wire sort lives here at the request-body boundary: it mirrors
        // the prompt's sorted order so leading bytes stay identical across rounds
        // and the server can reuse the cached prefix. Earlier helpers pass
        // definitions through unsorted so this stays the single ordering site.
        let ordered = VisionSchemaFilter.sortedByName(filtered.valid, name: { $0.name })
        if !ordered.isEmpty {
            body["tools"] = try ordered.map { tool -> [String: Any] in
                let parsed = try encodeToolParameters(tool)
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": parsed
                    ]
                ]
            }
            body["tool_choice"] = "auto"
        }
    }
    do {
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    } catch {
        throw LLMProviderError.invalidResponse("Could not encode chat request: \(error.localizedDescription)")
    }
}

/// Validates and returns tool call arguments for the wire, falling back to "{}" if malformed.
/// Protects OpenAI-compatible and llama.cpp endpoints (which strictly parse arguments as JSON)
/// from 500 errors when encountering legacy truncated placeholders (e.g. ending in '…') or invalid syntax.
/// The wire expects an object string, so non-object valid JSON (arrays, scalars, null) also falls back.
func sanitizedToolCallArgumentsJSON(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "{}" }
    guard let data = trimmed.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          parsed is [String: Any]
    else {
        return "{}"
    }
    return trimmed
}

/// Parses one persisted assistant placeholder line into a structured call.
func parseResponsesPlaceholderLine(_ line: String) -> ToolCall? {
    guard let parsed = ToolInput.parsePlaceholderLine(line) else { return nil }
    return ToolCall(id: parsed.callID, name: parsed.toolName, argumentsJSON: parsed.argumentsJSON)
}

/// Collects the call IDs that already have a tool-role result among `messages`.
/// Single-sources the answer set for both wires so an assistant placeholder is
/// promoted to a native call only once its result exists in the same request.
func answeredToolCallIDs(in messages: [Message]) -> Set<String> {
    Set(messages.compactMap { $0.role == .tool ? $0.toolCallID : nil })
}

/// Outcome of splitting one assistant message into wire-ready calls plus text.
/// Named fields replace a multi-member tuple so each of the split's three
/// outcomes stays self-documenting at both request-body call sites.
struct ResponsesAssistantContentSplit: Sendable {
    /// Promoted placeholders, in first-seen order.
    let toolCalls: [ToolCall]
    /// Non-placeholder text retained verbatim alongside the promoted calls.
    let leftover: String
    /// Whether any placeholder line was recognized; callers use this to replace the
    /// raw note with its leftover prose while dropping a fully scrubbed plumbing note.
    let recognizedPlumbing: Bool
}

/// Splits an assistant message into structured calls plus leftover text.
/// - Parameter answeredCallIDs: When provided, a parsed placeholder whose call ID
///   has no matching tool result is scrubbed from the wire entirely instead of
///   becoming a call, so dangling parked/gated placeholders neither reach the wire
///   as unmatched calls nor leak their raw `Calling …` text as content. Passing nil
///   promotes every parsed placeholder, preserving the result-free split used by
///   callers that validate placeholders in isolation.
/// - Parameter excludingCallIDs: Identifiers already emitted earlier in this request.
///   A placeholder carrying one drops entirely so a single call ID never maps to two
///   wire entries; a repeat inside this note collapses the same way.
/// - Returns: The split result carrying structured calls, leftover text, and whether
///   any placeholder line was recognized.
func splitResponsesAssistantContent(
    _ content: String,
    answeredCallIDs: Set<String>? = nil,
    excludingCallIDs: Set<String> = []
) -> ResponsesAssistantContentSplit {
    // Shared split keeps wire validation on the same line boundaries as narration
    // parsing; a trailing newline stays a terminator, not an extra blank.
    var emitted = excludingCallIDs
    var calls: [ToolCall] = []
    var leftoverLines: [String] = []
    var recognizedPlumbing = false
    for rawLine in NormalizedText.splitLines(content) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { continue }
        if let call = parseResponsesPlaceholderLine(line) {
            recognizedPlumbing = true
            // One call ID yields exactly one wire call. A repeated line is the
            // narration plus its previously emitted twin, so drop it outright
            // rather than leaking plumbing back into the leftover text.
            guard emitted.insert(call.id).inserted else { continue }
            if let answeredCallIDs, !answeredCallIDs.contains(call.id) {
                // Dangling placeholder: a parked or approval-gated call has no
                // result in this request, so promoting it would send an unmatched
                // call. Scrub the line entirely rather than re-emitting the raw
                // `Calling …` plumbing as request content; genuine prose on this
                // same note still survives through the else branch below.
                continue
            }
            calls.append(call)
        } else {
            leftoverLines.append(rawLine)
        }
    }
    return ResponsesAssistantContentSplit(
        toolCalls: calls,
        leftover: leftoverLines.joined(separator: "\n"),
        recognizedPlumbing: recognizedPlumbing
    )
}

/// Builds a JSON request body for `/responses`.
/// - Parameters:
///   - cachePrompt: llama.cpp-only KV-cache hint; nil omits the key so cloud providers are unaffected.
///   - slotID: llama.cpp-only sticky slot; nil omits the key so the server auto-assigns.
func openAIResponsesRequestBody(
    model: String,
    messages: [Message],
    tools: [ToolDefinition],
    stream: Bool,
    cachePrompt: Bool? = nil,
    slotID: Int? = nil
) throws -> Data {
    let systemMessages = messages.filter { $0.role == .system }
    let conversationMessages = messages.filter { $0.role != .system }
    let ordered = systemMessages + conversationMessages
    // Responses shares the chat wire's dangling-call hazard: a `function_call`
    // item with no matching `function_call_output` is rejected, and parked/gated
    // notes persist without results until approval. Gate promotion on the same set.
    let answeredCallIDs = answeredToolCallIDs(in: messages)
    // Same cross-note guard as the chat wire: one call ID produces one
    // `function_call` item even when a later note re-persists its placeholder.
    var emittedCallIDs = Set<String>()
    var wireInput: [[String: Any]] = []
    wireInput.reserveCapacity(ordered.count * 2)
    for message in ordered {
        if message.role == .tool {
            wireInput.append([
                "type": "function_call_output",
                "call_id": message.toolCallID ?? "",
                "output": message.content
            ])
            continue
        }
        if message.role == .assistant {
            let split = splitResponsesAssistantContent(
                message.content,
                answeredCallIDs: answeredCallIDs,
                excludingCallIDs: emittedCallIDs
            )
            if !split.toolCalls.isEmpty {
                emittedCallIDs.formUnion(split.toolCalls.map(\.id))
                for call in split.toolCalls {
                    wireInput.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": sanitizedToolCallArgumentsJSON(call.argumentsJSON)
                    ])
                }
            }
            if split.recognizedPlumbing {
                // A plumbing note contributes only its leftover prose, so a scrubbed
                // dangling line or an excluded twin vanishes rather than leaking
                // `Calling …` upstream as request content.
                let leftover = split.leftover.trimmingCharacters(in: .whitespacesAndNewlines)
                if !leftover.isEmpty {
                    wireInput.append([
                        "role": "assistant",
                        "content": [["type": "output_text", "text": leftover]]
                    ])
                }
                continue
            }
            wireInput.append([
                "role": "assistant",
                "content": [["type": "output_text", "text": message.content]]
            ])
            continue
        }
        wireInput.append([
            "role": OpenAIWireRole.string(for: message.role),
            "content": [["type": "input_text", "text": message.content]]
        ])
    }
    if wireInput.isEmpty {
        wireInput = [["role": "user", "content": [["type": "input_text", "text": ""]]]]
    }
    var body: [String: Any] = [
        "model": model,
        "input": wireInput,
        "stream": stream
    ]
    // Same llama.cpp-only prefix hints as the chat wire, behind the same
    // optionals so cloud requests never see them; absent values omit the keys.
    if let cachePrompt {
        body["cache_prompt"] = cachePrompt
    }
    if let slotID {
        body["id_slot"] = slotID
    }
    if !tools.isEmpty {
        // Omit invalid entries so a turn with zero valid tools proceeds text-only instead of throwing.
        let filtered = validatedDefinitions(tools)
        // Same canonical sort as the chat wire so both endpoints share one prefix
        // from this boundary layer; callers arrive unsorted by contract.
        let ordered = VisionSchemaFilter.sortedByName(filtered.valid, name: { $0.name })
        if !ordered.isEmpty {
            body["tools"] = try ordered.map { tool -> [String: Any] in
                let parsed = try encodeToolParameters(tool)
                return [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": parsed
                ]
            }
        }
    }
    do {
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    } catch {
        throw LLMProviderError.invalidResponse("Could not encode responses request: \(error.localizedDescription)")
    }
}
