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
    var wireMessages: [[String: Any]] = messages.map { message in
        var entry: [String: Any] = [
            "role": OpenAIWireRole.string(for: message.role),
            "content": message.content
        ]
        if let callID = message.toolCallID {
            entry["tool_call_id"] = callID
        }
        return entry
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

/// Parses one persisted assistant placeholder line into a structured call.
func parseResponsesPlaceholderLine(_ line: String) -> ToolCall? {
    guard let parsed = ToolInput.parsePlaceholderLine(line) else { return nil }
    return ToolCall(id: parsed.callID, name: parsed.toolName, argumentsJSON: parsed.argumentsJSON)
}

/// Splits an assistant message into structured calls plus leftover text.
func splitResponsesAssistantContent(_ content: String) -> (calls: [ToolCall], leftover: String) {
    // Shared split keeps wire validation on the same line boundaries as narration
    // parsing; a trailing newline stays a terminator, not an extra blank.
    var calls: [ToolCall] = []
    var leftoverLines: [String] = []
    for rawLine in NormalizedText.splitLines(content) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { continue }
        if let call = parseResponsesPlaceholderLine(line) {
            calls.append(call)
        } else {
            leftoverLines.append(rawLine)
        }
    }
    return (calls, leftoverLines.joined(separator: "\n"))
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
            let split = splitResponsesAssistantContent(message.content)
            if !split.calls.isEmpty {
                for call in split.calls {
                    wireInput.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.argumentsJSON
                    ])
                }
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
