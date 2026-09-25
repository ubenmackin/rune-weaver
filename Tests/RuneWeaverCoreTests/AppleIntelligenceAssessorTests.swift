// Rune Weaver Tests — Apple Intelligence tool safety assessment and permission models.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Apple Intelligence and Tool Safety Assessment")
struct AppleIntelligenceAssessorTests {
    @Test
    func `PermissionRequest encodes and decodes with intent and assessment`() throws {
        let assessment = ImpactAssessment(
            severity: .dangerous,
            outcome: "Permanently deletes project build directory.",
            warnings: ["Irreversible file deletion."]
        )
        let request = PermissionRequest(
            toolName: "terminal.run",
            description: "Run shell command",
            input: ToolInput(toolName: "terminal.run", argumentsJSON: #"{"command":"rm -rf .build"}"#),
            suggestedDurations: [.thisTime],
            sessionID: UUID(),
            intent: "Freeing disk space before rebuild",
            assessment: assessment
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PermissionRequest.self, from: encoded)

        #expect(decoded.id == request.id)
        #expect(decoded.toolName == "terminal.run")
        #expect(decoded.intent == "Freeing disk space before rebuild")
        #expect(decoded.assessment?.severity == .dangerous)
        #expect(decoded.assessment?.outcome == "Permanently deletes project build directory.")
        #expect(decoded.assessment?.warnings == ["Irreversible file deletion."])
    }

    @Test
    func `PermissionRequest decodes legacy payloads missing intent and assessment`() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "toolName": "files.read",
            "description": "Read file contents",
            "input": {
                "toolName": "files.read",
                "argumentsJSON": "{}",
                "callID": "call-1"
            },
            "suggestedDurations": ["thisTime"]
        }
        """

        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(PermissionRequest.self, from: data)

        #expect(decoded.toolName == "files.read")
        #expect(decoded.description == "Read file contents")
        #expect(decoded.intent == nil)
        #expect(decoded.assessment == nil)
    }

    @Test
    func `FallbackHeuristics classifies read-only tools as safe`() {
        let assessment = FallbackHeuristics.evaluate(
            toolName: "files.read",
            argumentsJSON: #"{"path":"README.md"}"#,
            intent: "Checking project documentation"
        )
        #expect(assessment.severity == .safe)
        #expect(assessment.warnings.isEmpty)
    }

    @Test
    func `FallbackHeuristics classifies destructive commands as dangerous with warnings`() {
        let assessment = FallbackHeuristics.evaluate(
            toolName: "terminal.run",
            argumentsJSON: #"{"command":"rm -rf /tmp/cache"}"#,
            intent: "Cleaning temporary cache"
        )
        #expect(assessment.severity == .dangerous)
        #expect(!assessment.warnings.isEmpty)
        #expect(assessment.warnings.contains(where: { $0.contains("Permanently deletes") }))
    }

    @Test
    func `FallbackHeuristics classifies desktop control as dangerous`() {
        let assessment = FallbackHeuristics.evaluate(
            toolName: "desktop.action",
            argumentsJSON: #"{"action":"click"}"#,
            intent: "Clicking target button"
        )
        #expect(assessment.severity == .dangerous)
        #expect(assessment.warnings.contains(where: { $0.contains("CGEvent") || $0.contains("hardware") }))
    }

    @Test
    func `FallbackHeuristics classifies normal writes as moderate`() {
        let assessment = FallbackHeuristics.evaluate(
            toolName: "files.write",
            argumentsJSON: #"{"path":"test.txt","content":"hello"}"#,
            intent: "Writing output file"
        )
        #expect(assessment.severity == .moderate)
    }

    @Test
    func `FallbackHeuristics classifies engine continuation as moderate`() {
        let assessment = FallbackHeuristics.evaluate(
            toolName: "engine.continue",
            argumentsJSON: #"{"rounds":5}"#
        )
        #expect(assessment.severity == .moderate)
        #expect(assessment.outcome.contains("additional tool execution rounds"))
    }

    @Test
    func `AppleIntelligenceAssessor parses valid JSON responses accurately`() {
        let jsonResponse = """
        Here is the evaluation:
        {
            "severity": "dangerous",
            "outcome": "Will permanently delete all files in the build directory.",
            "warnings": ["Data loss risk"]
        }
        """
        let parsed = AppleIntelligenceAssessor.parseAssessmentJSON(jsonResponse)
        #expect(parsed != nil)
        #expect(parsed?.severity == .dangerous)
        #expect(parsed?.outcome == "Will permanently delete all files in the build directory.")
        #expect(parsed?.warnings == ["Data loss risk"])
    }

    @Test
    func `AppleIntelligenceAssessor returns nil for malformed text`() {
        let badResponse = "This is not valid json at all."
        let parsed = AppleIntelligenceAssessor.parseAssessmentJSON(badResponse)
        #expect(parsed == nil)
    }
}
