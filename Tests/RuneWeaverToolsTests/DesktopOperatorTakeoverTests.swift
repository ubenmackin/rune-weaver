// Rune Weaver Tools Tests — Desktop operator takeover and resume tests.
import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

@Suite("Desktop Operator Takeover Tests")
struct DesktopOperatorTakeoverTests {
    #if canImport(CoreGraphics)
        @Test
        func `Displacement calculation identifies movements beyond threshold`() {
            let origin = CGPoint(x: 200, y: 200)

            // Sub-threshold movement (< 15pt)
            let subtleMove = CGPoint(x: 205, y: 205)
            #expect(!DesktopControlBridge.isDisplaced(actual: subtleMove, from: origin))

            // Large movement (> 15pt, e.g. operator moving mouse)
            let operatorMove = CGPoint(x: 220, y: 200)
            #expect(DesktopControlBridge.isDisplaced(actual: operatorMove, from: origin))

            let diagonalOperatorMove = CGPoint(x: 215, y: 215)
            #expect(DesktopControlBridge.isDisplaced(actual: diagonalOperatorMove, from: origin))
        }
    #endif

    @Test
    func `DesktopControlMonitor tracks and clears operator takeover latch`() async {
        let monitor = DesktopControlMonitor()
        let initial = await monitor.isOperatorTakeoverRequested
        #expect(!initial)

        await monitor.requestOperatorTakeover()
        let afterRequest = await monitor.isOperatorTakeoverRequested
        #expect(afterRequest)

        await monitor.clearEmergencyStop()
        let afterClear = await monitor.isOperatorTakeoverRequested
        #expect(!afterClear)
    }

    @Test
    func `DesktopControlBridge throws operatorTakeover when detector triggers`() async throws {
        let bridge = DesktopControlBridge(
            accessibilityAccess: { true },
            operatorTakeoverDetector: { true }
        )

        do {
            _ = try await bridge.executeBatch(
                actions: [.delay(milliseconds: 10)],
                scaleX: 1.0,
                scaleY: 1.0,
                blockedApps: []
            )
            Issue.record("Expected DesktopControlError.operatorTakeover to be thrown")
        } catch let error as DesktopControlError {
            guard case .operatorTakeover = error else {
                Issue.record("Expected operatorTakeover error, got: \(error)")
                return
            }
        }
    }

    @Test
    func `DesktopActionTool wraps operatorTakeover as structured envelope`() async throws {
        struct TakeoverFailingBridge: DesktopControlling, Sendable {
            func executeBatch(
                actions _: [DesktopAction],
                scaleX _: Double,
                scaleY _: Double,
                blockedApps _: [String]
            ) async throws -> [DesktopActionStepResult] {
                throw DesktopControlError.operatorTakeover
            }

            func executeBatch(
                actions _: [DesktopAction],
                scaleX _: Double,
                scaleY _: Double,
                blockedApps _: [String],
                sessionID _: UUID?
            ) async throws -> [DesktopActionStepResult] {
                throw DesktopControlError.operatorTakeover
            }
        }

        let tool = DesktopActionTool(controlBridge: TakeoverFailingBridge())
        let input = ToolInput(
            toolName: "desktop.action",
            argumentsJSON: #"{"actions": [{"action": "click", "x": 100, "y": 100}]}"#
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))

        #expect(!output.isError)
        #expect(output.content.contains("\"operatorInterrupted\""))
        #expect(output.content.contains("OPERATOR TAKEOVER"))

        let data = try #require(output.content.data(using: .utf8))
        let envelope = try JSONDecoder().decode(DesktopActionEnvelope.self, from: data)
        #expect(envelope.success == false)
        #expect(envelope.operatorInterrupted == true)
        #expect(envelope.error?.contains("OPERATOR TAKEOVER") == true)
    }
}
