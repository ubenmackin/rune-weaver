// Rune Weaver Tools Tests — Desktop vision and control tool tests.
import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

// MARK: - Test Doubles

private struct StubDesktopCaptureBridge: DesktopCapturing, Sendable {
    var shouldFail: Bool = false
    var failWithPermissionDenied: Bool = false
    var windowsToReturn: [DesktopWindowInfo] = []

    func captureDisplay(
        displayIndex: Int,
        maxDimension _: Int,
        jpegQuality _: Double
    ) async throws -> DesktopCaptureResult {
        if failWithPermissionDenied {
            throw DesktopCaptureError.screenRecordingPermissionDenied
        }
        if shouldFail || displayIndex > 1 {
            throw DesktopCaptureError.displayNotFound(index: displayIndex)
        }
        return DesktopCaptureResult(
            screenshotDataURL: "data:image/jpeg;base64,stubdisplaydata",
            screenshotHash: "stubhash123",
            originalWidth: 2560,
            originalHeight: 1440,
            scaledWidth: 1280,
            scaledHeight: 720,
            scaleX: 2.0,
            scaleY: 2.0,
            displayIndex: displayIndex,
            targetApp: nil
        )
    }

    func captureWindow(
        appName: String,
        maxDimension _: Int,
        jpegQuality _: Double
    ) async throws -> DesktopCaptureResult {
        if appName == "NonExistentApp" {
            throw DesktopCaptureError.windowNotFound(appName: appName)
        }
        return DesktopCaptureResult(
            screenshotDataURL: "data:image/jpeg;base64,stubwindowdata",
            screenshotHash: "stubwindowhash456",
            originalWidth: 1600,
            originalHeight: 900,
            scaledWidth: 1280,
            scaledHeight: 720,
            scaleX: 1.25,
            scaleY: 1.25,
            displayIndex: 0,
            targetApp: appName
        )
    }

    func listWindows() async -> [DesktopWindowInfo] {
        windowsToReturn
    }
}

private struct StubDesktopControlBridge: DesktopControlling, Sendable {
    var shouldFailCorner: Bool = false
    var shouldFailBlocked: String?

    func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps _: [String]
    ) async throws -> [DesktopActionStepResult] {
        if actions.count > DesktopControlBridge.maxBatchSize {
            throw DesktopControlError.batchTooLarge(count: actions.count, max: DesktopControlBridge.maxBatchSize)
        }
        if shouldFailCorner {
            throw DesktopControlError.failSafeTriggered
        }
        if let blocked = shouldFailBlocked {
            throw DesktopControlError.blockedApp(appName: blocked)
        }

        var results: [DesktopActionStepResult] = []
        for (idx, action) in actions.enumerated() {
            let msg = switch action {
            case let .switchApp(app):
                "Switched to \(app)"
            case let .click(x, y, button, _):
                "Clicked \(button) at (\(Int(x * scaleX)), \(Int(y * scaleY)))"
            case let .typeText(text):
                "Typed \"\(text)\""
            case let .keyPress(key, _):
                "Pressed \(key)"
            default:
                "Executed \(action)"
            }
            results.append(DesktopActionStepResult(
                index: idx,
                action: action,
                success: true,
                message: msg
            ))
        }
        return results
    }
}

// MARK: - Test Suite

@Suite("Desktop Tools")
struct DesktopToolsTests {
    // MARK: - Registration & Gating

    @Test
    func `Desktop tools are not registered when desktop config is disabled`() {
        var config = DesktopConfig()
        config.enabled = false
        config.controlEnabled = true

        let tools = DesktopTools.makeTools(desktopConfig: config)
        #expect(tools.isEmpty)
        #expect(DesktopTools.toolNames(for: config).isEmpty)
    }

    @Test
    func `Only screenshot tool is registered when control is disabled`() {
        var config = DesktopConfig()
        config.enabled = true
        config.screenCaptureEnabled = true
        config.controlEnabled = false

        let tools = DesktopTools.makeTools(desktopConfig: config)
        #expect(tools.count == 1)
        #expect(tools.first?.name == DesktopTools.screenshotToolName)
        #expect(DesktopTools.toolNames(for: config) == [DesktopTools.screenshotToolName])
    }

    @Test
    func `Both tools are registered when enabled and controlEnabled are true`() {
        var config = DesktopConfig()
        config.enabled = true
        config.screenCaptureEnabled = true
        config.controlEnabled = true

        let tools = DesktopTools.makeTools(desktopConfig: config)
        #expect(tools.count == 2)
        let names = tools.map(\.name)
        #expect(names.contains(DesktopTools.screenshotToolName))
        #expect(names.contains(DesktopTools.actionToolName))
    }

    @Test
    func `Tool permissions conform to design specification`() {
        let screenshot = DesktopScreenshotTool(captureBridge: StubDesktopCaptureBridge())
        let action = DesktopActionTool(controlBridge: StubDesktopControlBridge())

        #expect(screenshot.permissionLevel == .readOnly)
        #expect(action.permissionLevel == .requiresApproval)
    }

    // MARK: - Screenshot Tool Execution

    @Test
    func `Desktop screenshot captures display and returns valid envelope`() async throws {
        let stub = StubDesktopCaptureBridge()
        let tool = DesktopScreenshotTool(captureBridge: stub)

        let input = ToolInput(
            toolName: "desktop.screenshot",
            argumentsJSON: #"{"display": 0}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(!output.isError)
        let data = try #require(output.content.data(using: .utf8))
        let envelope = try JSONDecoder().decode(DesktopScreenshotEnvelope.self, from: data)

        #expect(envelope.screenshotDataURL == "data:image/jpeg;base64,stubdisplaydata")
        #expect(envelope.screenshotHash == "stubhash123")
        #expect(envelope.originalWidth == 2560)
        #expect(envelope.originalHeight == 1440)
        #expect(envelope.scaledWidth == 1280)
        #expect(envelope.scaledHeight == 720)
        #expect(envelope.scaleX == 2.0)
        #expect(envelope.scaleY == 2.0)
        #expect(envelope.displayIndex == 0)
        #expect(envelope.targetApp == nil)
    }

    @Test
    func `Desktop screenshot targets specific window and includes window list`() async throws {
        var stub = StubDesktopCaptureBridge()
        stub.windowsToReturn = [
            DesktopWindowInfo(appName: "Photos", windowTitle: "Library", x: 100, y: 100, width: 800, height: 600, isFrontmost: true),
            DesktopWindowInfo(appName: "Finder", windowTitle: "Downloads", x: 200, y: 200, width: 600, height: 400, isFrontmost: false)
        ]
        let tool = DesktopScreenshotTool(captureBridge: stub)

        let input = ToolInput(
            toolName: "desktop.screenshot",
            argumentsJSON: #"{"target_app": "Photos", "include_windows_list": true}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(!output.isError)
        let data = try #require(output.content.data(using: .utf8))
        let envelope = try JSONDecoder().decode(DesktopScreenshotEnvelope.self, from: data)

        #expect(envelope.targetApp == "Photos")
        #expect(envelope.windows?.count == 2)
        #expect(envelope.windows?.first?.appName == "Photos")
    }

    @Test
    func `Desktop screenshot returns friendly error when window not found`() async throws {
        let stub = StubDesktopCaptureBridge()
        let tool = DesktopScreenshotTool(captureBridge: stub)

        let input = ToolInput(
            toolName: "desktop.screenshot",
            argumentsJSON: #"{"target_app": "NonExistentApp"}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(output.isError)
        #expect(output.content.contains("No visible window found"))
    }

    @Test
    func `Desktop screenshot returns friendly error when permission is denied`() async throws {
        var stub = StubDesktopCaptureBridge()
        stub.failWithPermissionDenied = true
        let tool = DesktopScreenshotTool(captureBridge: stub)

        let input = ToolInput(
            toolName: "desktop.screenshot",
            argumentsJSON: "{}"
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(output.isError)
        #expect(output.content.contains("Screen Recording permission is required"))
    }

    // MARK: - Action Tool Execution

    @Test
    func `Desktop action executes a batch of actions successfully`() async throws {
        let stub = StubDesktopControlBridge()
        let tool = DesktopActionTool(controlBridge: stub)

        let json = """
        {
            "actions": [
                {"action": "switch_app", "app_name": "Safari"},
                {"action": "click", "x": 500, "y": 300, "button": "left"},
                {"action": "type_text", "text": "Hello World"},
                {"action": "key_press", "key": "Return"}
            ],
            "scale_x": 2.0,
            "scale_y": 2.0
        }
        """
        let input = ToolInput(toolName: "desktop.action", argumentsJSON: json)
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(!output.isError)
        let data = try #require(output.content.data(using: .utf8))
        let envelope = try JSONDecoder().decode(DesktopActionEnvelope.self, from: data)

        #expect(envelope.success == true)
        #expect(envelope.stepsCompleted == 4)
        #expect(envelope.stepsTotal == 4)
        #expect(envelope.results.count == 4)
        #expect(envelope.results[0].message == "Switched to Safari")
        #expect(envelope.results[1].message.contains("Clicked left at (1000, 600)"))
        #expect(envelope.results[2].message.contains("Typed \"Hello World\""))
        #expect(envelope.results[3].message.contains("Pressed Return"))
    }

    @Test
    func `Desktop action enforces blocked application safety guardrail`() async throws {
        var stub = StubDesktopControlBridge()
        stub.shouldFailBlocked = "Terminal"
        let tool = DesktopActionTool(controlBridge: stub)

        let json = """
        {
            "actions": [
                {"action": "type_text", "text": "rm -rf /"}
            ]
        }
        """
        let input = ToolInput(toolName: "desktop.action", argumentsJSON: json)
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(output.isError)
        #expect(output.content.contains("SAFETY"))
        #expect(output.content.contains("Terminal"))
        #expect(output.content.contains("blocked-app list"))
    }

    @Test
    func `Desktop action aborts when fail-safe corner is triggered`() async throws {
        var stub = StubDesktopControlBridge()
        stub.shouldFailCorner = true
        let tool = DesktopActionTool(controlBridge: stub)

        let json = """
        {
            "actions": [
                {"action": "click", "x": 100, "y": 100}
            ]
        }
        """
        let input = ToolInput(toolName: "desktop.action", argumentsJSON: json)
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(output.isError)
        #expect(output.content.contains("FAIL-SAFE TRIGGERED"))
    }

    @Test
    func `Desktop action rejects batches exceeding maximum size`() async throws {
        let stub = StubDesktopControlBridge()
        let tool = DesktopActionTool(controlBridge: stub)

        // Generate 25 actions (max is 20)
        let actions = (1 ... 25).map { _ in #"{"action": "delay", "milliseconds": 50}"# }.joined(separator: ", ")
        let json = "{\"actions\": [\(actions)]}"

        let input = ToolInput(toolName: "desktop.action", argumentsJSON: json)
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(output.isError)
        #expect(output.content.contains("Batch too large"))
    }

    @Test
    func `Both tools expose valid JSON Schema documents`() throws {
        let screenshot = DesktopScreenshotTool(captureBridge: StubDesktopCaptureBridge())
        let action = DesktopActionTool(controlBridge: StubDesktopControlBridge())

        let screenshotData = try #require(screenshot.inputSchema.rawValue.data(using: .utf8))
        let screenshotParsed = try JSONSerialization.jsonObject(with: screenshotData) as? [String: Any]
        #expect(screenshotParsed?["type"] as? String == "object")
        #expect(screenshotParsed?["properties"] != nil)

        let actionData = try #require(action.inputSchema.rawValue.data(using: .utf8))
        let actionParsed = try JSONSerialization.jsonObject(with: actionData) as? [String: Any]
        #expect(actionParsed?["type"] as? String == "object")
        #expect(actionParsed?["properties"] != nil)
    }
}
