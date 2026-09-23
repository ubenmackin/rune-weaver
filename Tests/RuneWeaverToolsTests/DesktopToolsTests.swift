// Rune Weaver Tools Tests — Desktop vision and control tool tests.
import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

// MARK: - Test Doubles

private struct StubDesktopCaptureBridge: DesktopCapturing, Sendable {
    var shouldFail: Bool = false
    var failWithPermissionDenied: Bool = false
    var failWindowsListWithPermissionDenied: Bool = false
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
        // Mirror the display path so window captures exercise the same
        // fail-closed denial instead of succeeding while the display path
        // denies; keeps the stub honest about the shared silent gate.
        if failWithPermissionDenied {
            throw DesktopCaptureError.screenRecordingPermissionDenied
        }
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

    func listWindows() async throws -> [DesktopWindowInfo] {
        // Throw instead of returning an empty list so the tool-level test
        // can verify denials surface permission guidance rather than a
        // silent omission of the window section.
        if failWindowsListWithPermissionDenied || failWithPermissionDenied {
            throw DesktopCaptureError.screenRecordingPermissionDenied
        }
        return windowsToReturn
    }
}

private struct StubDesktopControlBridge: DesktopControlling, Sendable {
    var shouldFailCorner: Bool = false
    var shouldFailBlocked: String?
    var shouldDenyAccessibilityPermission: Bool = false

    func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps _: [String]
    ) async throws -> [DesktopActionStepResult] {
        if shouldDenyAccessibilityPermission {
            throw DesktopControlError.accessibilityPermissionDenied
        }
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

@Suite("Desktop Tools", .serialized)
struct DesktopToolsTests {
    // The control bridge reads the process-wide emergency-stop latch, so this
    // suite serializes internally: a stop latched by one test must never leak
    // into a neighbor expecting a permission denial.
    // MARK: - Registration & Gating (always registered, fail-closed gates)

    @Test
    func `Both tools always register regardless of config`() {
        // Visibility in GET /tools never depends on config: the stock
        // install still exposes both tools so the surface stays inspectable
        // instead of shape-shifting. Enablement flows through tool-state.
        let config = DesktopConfig()

        let tools = DesktopTools.makeTools(desktopConfig: config)
        #expect(tools.count == 2)
        #expect(tools.map(\.name) == DesktopTools.allToolNames)
        #expect(DesktopTools.toolNames(for: config) == DesktopTools.allToolNames)
    }

    @Test
    func `Toggled and default configs still expose both tool names`() {
        let configs: [DesktopConfig] = [DesktopConfig(), DesktopConfig()]
        for config in configs {
            #expect(DesktopTools.toolNames(for: config) == DesktopTools.allToolNames)
            #expect(DesktopTools.makeTools(desktopConfig: config).count == 2)
        }
    }

    @Test
    func `Default config carries only capture knobs`() {
        // A stock install never implies live capture: capture knobs ship
        // with safe defaults and the tools ship disabled at boot until the
        // operator enables the tool-state toggle.
        let config = DesktopConfig()
        #expect(config.maxImageDimension == DesktopConfig.defaultMaxImageDimension)
        #expect(config.jpegQuality == DesktopConfig.defaultJpegQuality)
        #expect(config.blockedApps.contains("Terminal"))
    }

    @Test
    func `Builtin registration ships both desktop tools disabled`() async {
        // Boot-path contract: every tool registers, non-desktop tools stay
        // enabled, and desktop tools arrive disabled until the restore path
        // re-applies persisted rows with no config gate.
        let bus = ToolBus()
        await BuiltinToolPlugins.registerAll(on: bus)

        #expect(await bus.tool(named: DesktopTools.screenshotToolName) != nil)
        #expect(await bus.tool(named: DesktopTools.actionToolName) != nil)
        #expect(await bus.isToolEnabled(named: DesktopTools.screenshotToolName) == false)
        #expect(await bus.isToolEnabled(named: DesktopTools.actionToolName) == false)
        #expect(await bus.isToolEnabled(named: "files.read") == true)
        #expect(await !(bus.availableTools().contains { DesktopTools.allToolNames.contains($0.name) }))
        #expect(await bus.allTools().contains { DesktopTools.allToolNames.contains($0.name) })
    }

    @Test
    func `Tool-state toggle is the sole authority for desktop tools`() async {
        // Single-gate contract: enabling through the bus sticks with no
        // config gate overriding it, and both tools stay registered while
        // disabled by default.
        let bus = ToolBus()
        for tool in DesktopTools.makeTools() {
            await bus.register(tool: tool, isEnabled: false)
        }
        #expect(await bus.tool(named: DesktopTools.screenshotToolName) != nil)
        #expect(await bus.isToolEnabled(named: DesktopTools.screenshotToolName) == false)
        #expect(await bus.isToolEnabled(named: DesktopTools.actionToolName) == false)

        await bus.enableTool(named: DesktopTools.screenshotToolName)
        #expect(await bus.isToolEnabled(named: DesktopTools.screenshotToolName) == true)
        await bus.enableTool(named: DesktopTools.actionToolName)
        #expect(await bus.isToolEnabled(named: DesktopTools.actionToolName) == true)
    }

    @Test
    func `Newly registered desktop tools ship disabled until toggled`() async {
        // Mirrors the media live-reload pattern: a tool absent from the bus
        // reports disabled, so re-registration preserves live state while
        // fresh entries arrive disabled rather than model-visible.
        let config = DesktopConfig()
        let bus = ToolBus()
        for tool in DesktopTools.makeTools(desktopConfig: config) {
            let isEnabled = await bus.isToolEnabled(named: tool.name)
            #expect(isEnabled == false)
            await bus.register(tool: tool, isEnabled: isEnabled)
        }
        #expect(await bus.tool(named: DesktopTools.screenshotToolName) != nil)
        #expect(await bus.tool(named: DesktopTools.actionToolName) != nil)
        #expect(await bus.isToolEnabled(named: DesktopTools.screenshotToolName) == false)
        #expect(await bus.isToolEnabled(named: DesktopTools.actionToolName) == false)
        #expect(await bus.availableTools().isEmpty)
        #expect(await bus.allTools().count == 2)
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
        #expect(output.content.contains("Screen Recording"))
        #expect(output.content.contains("System Settings"))
    }

    @Test
    func `Desktop screenshot denial guides through Settings toggle and relaunch`() async throws {
        // Fail-closed copy contract: a denied capture must leave the operator
        // with the exact Settings path, the toggle plus relaunch recovery,
        // and the first-capture prompt note, not just a bare permission sentence.
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
        #expect(output.content.contains("System Settings > Privacy & Security > Screen Recording"))
        #expect(output.content.contains("toggle the app/terminal on"))
        #expect(output.content.contains("quit + relaunch"))
        #expect(output.content.contains("auto-prompts on first capture"))
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
    func `Desktop action surfaces accessibility denial with recovery steps`() async throws {
        // Fail-closed copy contract: a denied turn must leave the operator
        // with the exact Settings path and toggle action, not just a bare
        // permission sentence, so they can unblock without another attempt.
        var stub = StubDesktopControlBridge()
        stub.shouldDenyAccessibilityPermission = true
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
        #expect(output.content.contains("Accessibility permission is required"))
        #expect(output.content.contains("System Settings > Privacy & Security > Accessibility"))
        #expect(output.content.contains("toggle the app/terminal on"))
        #expect(output.content.contains("quit + relaunch"))
    }

    @Test
    func `Desktop action accessibility denial explains CGEvent need`() async throws {
        // The why matters for trust: operators approve faster when the denial
        // names the gated capability instead of reading as a generic macOS nag.
        var stub = StubDesktopControlBridge()
        stub.shouldDenyAccessibilityPermission = true
        let tool = DesktopActionTool(controlBridge: stub)

        let json = """
        {
            "actions": [
                {"action": "type_text", "text": "hello"}
            ]
        }
        """
        let input = ToolInput(toolName: "desktop.action", argumentsJSON: json)
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(output.isError)
        #expect(output.content.contains("CGEvent"))
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

    // MARK: - Bridge Permission Gates (live gate, injected denial)

    @Test
    func `Capture bridge silent gate denies every entry point`() async {
        // Exercises the real fail-closed gate with an injected denial so the
        // test proves the bridge itself refuses before touching shareable
        // content, rather than trusting the stub to throw on its behalf.
        // The denial runs before the platform gate so it holds even where
        // ScreenCaptureKit is unavailable.
        let denied = DesktopCaptureBridge(screenRecordingAccess: { false })
        await #expect(throws: DesktopCaptureError.screenRecordingPermissionDenied) {
            try await denied.captureDisplay(displayIndex: 0, maxDimension: 1280, jpegQuality: 0.75)
        }
        await #expect(throws: DesktopCaptureError.screenRecordingPermissionDenied) {
            try await denied.captureWindow(appName: "Safari", maxDimension: 1280, jpegQuality: 0.75)
        }
        await #expect(throws: DesktopCaptureError.screenRecordingPermissionDenied) {
            try await denied.listWindows()
        }
    }

    @Test
    func `Control bridge silent gate denies without dispatch`() async {
        // Same hermetic pattern as the capture gate: the live bridge with a
        // denied silent check must refuse before validating the batch or
        // reaching CGEvent dispatch. Starts from a cleared latch because the
        // stop flag is shared process state that a neighbor test may latch.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let denied = DesktopControlBridge(accessibilityAccess: { false })
        await #expect(throws: DesktopControlError.accessibilityPermissionDenied) {
            try await denied.executeBatch(
                actions: [.delay(milliseconds: 10)],
                scaleX: 1.0,
                scaleY: 1.0,
                blockedApps: []
            )
        }
    }

    @Test
    func `Control bridge prefers emergency stop over permission denial`() async {
        // Ordering contract: an operator stop latched before the first step
        // aborts without paying a TCC syscall, so a stopped turn never
        // reports a permission error instead of the stop. Starts clean and
        // clears on every exit so the latched stop never leaks into neighbors.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let denied = DesktopControlBridge(accessibilityAccess: { false })
        await DesktopControlMonitor.shared.requestEmergencyStop()
        do {
            _ = try await denied.executeBatch(
                actions: [.delay(milliseconds: 10)],
                scaleX: 1.0,
                scaleY: 1.0,
                blockedApps: []
            )
            #expect(Bool(false), "Stopped batch should throw instead of succeeding")
        } catch let error as DesktopControlError {
            #expect(error == .emergencyStopped)
        } catch {
            #expect(Bool(false), "Expected an emergency stop, got \(error)")
        }
        await DesktopControlMonitor.shared.clearEmergencyStop()
    }

    @Test
    func `Control bridge prefers cancellation over permission denial`() async {
        // Same ordering contract for task cancellation: a cancelled turn
        // must surface cancellation rather than masking it behind a
        // permission error that would invite a pointless Settings trip.
        // Starts from a cleared latch so a neighbor's stop cannot mask the
        // cancellation signal under test.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let denied = DesktopControlBridge(accessibilityAccess: { false })
        let task = Task {
            try await denied.executeBatch(
                actions: [.delay(milliseconds: 10)],
                scaleX: 1.0,
                scaleY: 1.0,
                blockedApps: []
            )
        }
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            Issue.record("Cancelled batch should not succeed")
        case let .failure(error):
            // A cancelled turn must never mask cancellation behind a
            // permission error that would invite a pointless Settings trip.
            if let controlError = error as? DesktopControlError {
                #expect(controlError != .accessibilityPermissionDenied)
            }
        }
    }

    @Test
    func `Screenshot tool surfaces window-list denial instead of silent empty`() async throws {
        // Fail-closed list contract: a denied window scan fails the turn
        // with permission guidance so the model can tell "no permission"
        // apart from "no windows"; an empty success still means a genuine
        // scan found nothing.
        var stub = StubDesktopCaptureBridge()
        stub.failWindowsListWithPermissionDenied = true
        stub.windowsToReturn = [
            DesktopWindowInfo(appName: "Photos", windowTitle: "Library", x: 0, y: 0, width: 800, height: 600, isFrontmost: true)
        ]
        let tool = DesktopScreenshotTool(captureBridge: stub)

        let input = ToolInput(
            toolName: "desktop.screenshot",
            argumentsJSON: #"{"display": 0, "include_windows_list": true}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(output.isError)
        #expect(output.content.contains("Screen Recording permission is required"))
        #expect(output.content.contains("System Settings > Privacy & Security > Screen Recording"))
    }
}
