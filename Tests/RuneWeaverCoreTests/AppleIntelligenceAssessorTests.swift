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

/// Fixture stub tool for two-phase approval queue tests.
private struct AssessorBudgetStubTool: Tool, Sendable {
    let name: String
    var description: String {
        "Fixture stub for \(name)."
    }

    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    let permissionLevel: PermissionLevel = .requiresApproval

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("ok", callID: input.callID)
    }
}

@Suite("Assessor Budget Prewarm and Queue Two-Phase")
struct AssessorBudgetQueueTwoPhaseTests {
    @Test
    func `Assessment timeout equals 2_5 seconds`() {
        #expect(AppleIntelligenceAssessor.assessmentTimeoutSeconds == 2.5)
    }

    @Test
    func `Prewarm debounce interval equals 30 seconds`() {
        #expect(AppleIntelligenceAssessor.prewarmDebounceSeconds == 30)
    }

    @Test
    func `Prewarm never throws and returns immediately`() {
        // Non-throwing by construction: a bare call without try proves it.
        AppleIntelligenceAssessor.resetPrewarmForTesting()
        let start = Date()
        AppleIntelligenceAssessor.shared.prewarm()
        AppleIntelligenceAssessor.prewarm()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0)
        AppleIntelligenceAssessor.resetPrewarmForTesting()
    }

    @Test
    func `Prewarm debounces to at most once per 30 seconds`() {
        AppleIntelligenceAssessor.resetPrewarmForTesting()
        AppleIntelligenceAssessor.shared.prewarm()
        let first = AppleIntelligenceAssessor.lastPrewarmAtForTesting()
        #expect(first != nil)
        AppleIntelligenceAssessor.shared.prewarm()
        let second = AppleIntelligenceAssessor.lastPrewarmAtForTesting()
        #expect(second == first)
        AppleIntelligenceAssessor.resetPrewarmForTesting()
        #expect(AppleIntelligenceAssessor.lastPrewarmAtForTesting() == nil)
    }

    @Test
    func `Parse maps unknown severity to moderate with trimming`() {
        let parsed = AppleIntelligenceAssessor.parseAssessmentJSON("""
        {"severity": "  CRITICAL  ", "outcome": "  Does something.  ", "warnings": []}
        """)
        #expect(parsed?.severity == .moderate)
        #expect(parsed?.outcome == "Does something.")
        #expect(AppleIntelligenceAssessor.parseAssessmentJSON("""
        {"severity": "safe", "outcome": "Reads a file.", "warnings": []}
        """)?.severity == .safe)
        #expect(AppleIntelligenceAssessor.parseAssessmentJSON("""
        {"severity": "moderate", "outcome": "Writes a file.", "warnings": []}
        """)?.severity == .moderate)
        #expect(AppleIntelligenceAssessor.parseAssessmentJSON("""
        {"severity": "dangerous", "outcome": "Deletes everything.", "warnings": []}
        """)?.severity == .dangerous)
    }

    @Test
    func `FileRequest enqueues nil assessment immediately`() async {
        let queue = ApprovalQueue()
        let tool = AssessorBudgetStubTool(name: "files.write")
        let call = ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"a.txt"}"#)
        let start = Date()
        let pending = await queue.fileRequest(tool: tool, call: call, intent: "Writing")
        let elapsed = Date().timeIntervalSince(start)
        // Cold-model filing must not await the model budget.
        #expect(elapsed < 1.0)
        #expect(pending.assessment == nil)
        #expect(await queue.request(id: pending.id)?.id == pending.id)
        #expect(await queue.request(id: pending.id)?.assessment == nil)
        await queue.clear()
    }

    @Test
    func `Enriched update lands on identical id`() async {
        let queue = ApprovalQueue()
        let tool = AssessorBudgetStubTool(name: "files.write")
        let call = ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"b.txt"}"#)
        let pending = await queue.fileRequest(tool: tool, call: call)
        // Poll for the background enrichment (model budget plus scheduling jitter).
        var enriched: PermissionRequest?
        for _ in 0 ..< 120 {
            if let current = await queue.request(id: pending.id), current.assessment != nil {
                enriched = current
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let final = try? #require(enriched)
        #expect(final?.id == pending.id)
        #expect(final?.toolName == pending.toolName)
        #expect(final?.assessment != nil)
        await queue.clear()
    }

    @Test
    func `Explicit assessment enqueues directly with no child`() async {
        let queue = ApprovalQueue()
        await queue.setOnEnriched { _ in
            Issue.record("Enrichment must not run for explicit assessments")
        }
        let tool = AssessorBudgetStubTool(name: "files.write")
        let call = ToolInput(toolName: "files.write", argumentsJSON: "{}")
        let supplied = ImpactAssessment(severity: .safe, outcome: "Supplied.", warnings: [])
        let request = await queue.fileRequest(tool: tool, call: call, assessment: supplied)
        #expect(request.assessment == supplied)
        #expect(await queue.request(id: request.id)?.assessment == supplied)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await queue.request(id: request.id)?.assessment == supplied)
        await queue.setOnEnriched(nil)
        await queue.clear()
    }

    @Test
    func `UpdateAssessment preserves fields`() async {
        let queue = ApprovalQueue()
        let sessionID = UUID()
        let input = ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://example.com"}"#, callID: "call-1")
        let seeded = PermissionRequest(
            toolName: "api.request",
            description: "Call API",
            input: input,
            suggestedDurations: [.thisTime, .oneHour],
            sessionID: sessionID,
            intent: "Syncing",
            assessment: nil
        )
        await queue.enqueue(seeded)
        let enriched = ImpactAssessment(severity: .moderate, outcome: "Calls endpoint.", warnings: [])
        let updated = await queue.updateAssessment(id: seeded.id, assessment: enriched)
        let value = try? #require(updated)
        #expect(value?.id == seeded.id)
        #expect(value?.toolName == seeded.toolName)
        #expect(value?.description == seeded.description)
        #expect(value?.input == seeded.input)
        #expect(value?.suggestedDurations == seeded.suggestedDurations)
        #expect(value?.sessionID == seeded.sessionID)
        #expect(value?.intent == seeded.intent)
        #expect(value?.assessment == enriched)
        await queue.clear()
    }

    @Test
    func `UpdateAssessment no-ops on decided id`() async {
        let queue = ApprovalQueue()
        let tool = AssessorBudgetStubTool(name: "files.write")
        let call = ToolInput(toolName: "files.write", argumentsJSON: "{}")
        let pending = await queue.fileRequest(
            tool: tool,
            call: call,
            assessment: ImpactAssessment(severity: .safe, outcome: "Supplied.", warnings: [])
        )
        #expect(await queue.decide(id: pending.id, approved: true) == true)
        let late = await queue.updateAssessment(
            id: pending.id,
            assessment: ImpactAssessment(severity: .dangerous, outcome: "Late.", warnings: [])
        )
        #expect(late == nil)
        #expect(await queue.request(id: pending.id) == nil)
        await queue.clear()
    }

    @Test
    func `Decide during pending resolves with late enrichment dropped`() async {
        let queue = ApprovalQueue()
        let tool = AssessorBudgetStubTool(name: "files.write")
        let call = ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"late.txt"}"#)
        let pending = await queue.fileRequest(tool: tool, call: call)
        #expect(await queue.decide(id: pending.id, approved: true) == true)
        // Allow the model budget to elapse; the late result must not resurrect.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(await queue.request(id: pending.id) == nil)
        #expect(await queue.count() == 0)
        let late = await queue.updateAssessment(
            id: pending.id,
            assessment: ImpactAssessment(severity: .safe, outcome: "Late.", warnings: [])
        )
        #expect(late == nil)
        await queue.clear()
    }
}
