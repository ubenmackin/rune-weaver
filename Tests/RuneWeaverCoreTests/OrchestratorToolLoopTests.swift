// Rune Weaver Core Tests — Shared tool-loop policy for degraded schemas and tool-round notes.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Fixture tool with a configurable raw schema for degraded-schema tests.
private struct SchemaFixtureTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Raw JSON Schema document under test.
    let rawSchema: String
    /// Permission level; read-only keeps the fixture side-effect free.
    let permissionLevel = PermissionLevel.readOnly

    /// Human-readable description.
    var description: String {
        "Fixture stub for \(name)."
    }

    /// Schema as declared by the fixture.
    var inputSchema: JSONSchema {
        JSONSchema(rawValue: rawSchema)
    }

    /// Returns a canned outcome.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("ok", callID: input.callID)
    }
}

@Suite("Orchestrator Tool Loop")
struct OrchestratorToolLoopTests {
    @Test
    func `Degraded schema names withhold only broken registered tools`() {
        let valid = SchemaFixtureTool(name: "email.search", rawSchema: #"{"type":"object"}"#)
        let unparseable = SchemaFixtureTool(name: "broken.tool", rawSchema: "not-json")
        let wrongType = SchemaFixtureTool(name: "wrong.type", rawSchema: #"{"type":"string"}"#)
        let degraded = OrchestratorToolLoop.degradedSchemaNames(for: [valid, unparseable, wrongType])
        #expect(degraded == Set(["broken.tool", "wrong.type"]))
        #expect(!degraded.contains("email.search"))
    }

    @Test
    func `Unknown unregistered names stay outside the degraded denylist`() {
        // Unknown names never reach this filter, so they fall through to the bus and
        // get an `invalid_tool` answer with available-tool names for self-correction.
        let valid = SchemaFixtureTool(
            name: "email.search",
            rawSchema: #"{"type":"object","additionalProperties":false}"#
        )
        let degraded = OrchestratorToolLoop.degradedSchemaNames(for: [valid])
        #expect(degraded.isEmpty)
        #expect(!degraded.contains("missing.tool"))
        #expect(!degraded.contains("email.search"))
    }

    @Test
    func `Malformed additionalProperties withholds its schema`() {
        let malformed = SchemaFixtureTool(
            name: "odd.tool",
            rawSchema: #"{"type":"object","additionalProperties":7}"#
        )
        let degraded = OrchestratorToolLoop.degradedSchemaNames(for: [malformed])
        #expect(degraded == Set(["odd.tool"]))
    }

    @Test
    func `Narrated placeholder is not persisted as a duplicate twin`() {
        let call = ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"x"}"#, callID: "call_note_1")
        let narrated = ToolInput.placeholderContent(for: [call])
        let content = OrchestratorToolLoop.assistantNoteContent(text: narrated, calls: [call])
        let parsed = NormalizedText.splitLines(content).compactMap { ToolInput.parsePlaceholderLine($0) }
        #expect(parsed.count == 1)
        #expect(parsed.first?.callID == "call_note_1")
        #expect(parsed.first?.toolName == "email.search")
    }

    @Test
    func `Assistant note appends only calls missing from the narrated text`() {
        let narratedCall = ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"x"}"#, callID: "call_note_narrated")
        let nativeCall = ToolInput(toolName: "calendar.list", argumentsJSON: #"{"date":"today"}"#, callID: "call_note_native")
        let narrated = "Checking now.\n" + ToolInput.placeholderContent(for: [narratedCall])
        let content = OrchestratorToolLoop.assistantNoteContent(text: narrated, calls: [narratedCall, nativeCall])
        let parsed = NormalizedText.splitLines(content).compactMap { ToolInput.parsePlaceholderLine($0) }
        #expect(parsed.count == 2)
        #expect(parsed.filter { $0.callID == "call_note_narrated" }.count == 1)
        #expect(parsed.contains { $0.callID == "call_note_native" })
        #expect(content.contains("Checking now."))
    }

    @Test
    func `Assistant note collapses duplicate call identifiers`() {
        let first = ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"x"}"#, callID: "call_note_dup")
        let second = ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"y"}"#, callID: "call_note_dup")
        let content = OrchestratorToolLoop.assistantNoteContent(text: "", calls: [first, second])
        let parsed = NormalizedText.splitLines(content).compactMap { ToolInput.parsePlaceholderLine($0) }
        #expect(parsed.count == 1)
        #expect(parsed.first?.callID == "call_note_dup")
    }

    @Test
    func `Native call note keeps prose plus one generated placeholder`() {
        let call = ToolInput(toolName: "email.search", argumentsJSON: "{}", callID: "call_note_native_only")
        let content = OrchestratorToolLoop.assistantNoteContent(text: "Let me check.", calls: [call])
        #expect(content.hasPrefix("Let me check."))
        let parsed = NormalizedText.splitLines(content).compactMap { ToolInput.parsePlaceholderLine($0) }
        #expect(parsed.count == 1)
        #expect(parsed.first?.callID == "call_note_native_only")
    }
}
