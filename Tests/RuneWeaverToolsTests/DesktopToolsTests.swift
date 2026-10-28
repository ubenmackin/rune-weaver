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

    /// Mirrors the live bridge hint so stub denials carry identical
    /// operator guidance; one literal means drift shows as a diff here.
    private static let supportedKeyHint =
        "Return/Enter, Escape/Esc, Tab, Space, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp/Down, F1-F12, a-z, 0-9."

    /// Hardware codes mirrored from the live bridge table so the stub gate and the hermetic mapping
    /// test below read one list; UInt16 keeps the suite compiling where CoreGraphics is unavailable.
    fileprivate static let mirroredKeyCodes: [String: UInt16] = [
        "return": 0x24, "enter": 0x24,
        "escape": 0x35, "esc": 0x35,
        "tab": 0x30,
        "space": 0x31,
        "backspace": 0x33, "delete": 0x33,
        "forwarddelete": 0x75,
        "arrowup": 0x7E, "up": 0x7E,
        "arrowdown": 0x7D, "down": 0x7D,
        "arrowleft": 0x7B, "left": 0x7B,
        "arrowright": 0x7C, "right": 0x7C,
        "home": 0x73,
        "end": 0x77,
        "pageup": 0x74,
        "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02,
        "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
        "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
        "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
        "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
        "8": 0x1C, "9": 0x19
    ]

    /// Case-insensitive lookup over the mirrored table, matching the live
    /// bridge fold so capitalization never forks a chord.
    fileprivate static func keyCode(for key: String) -> UInt16? {
        mirroredKeyCodes[key.lowercased()]
    }

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
            // Mirror the live fail-closed rule so modified unmappable keys
            // refuse here too; keeps the unit suite hermetic without live
            // CGEvent dispatch for the unknown-key contract.
            if case let .keyPress(key, modifiers) = action,
               !modifiers.isEmpty, !isShortcutMappable(key)
            {
                throw DesktopControlError.actionFailed(
                    index: idx,
                    reason: "Unknown key name: '\(key)'. Supported: \(Self.supportedKeyHint)"
                )
            }
            let msg = switch action {
            case let .switchApp(app):
                "Switched to \(app)"
            case let .click(x, y, button, _):
                "Clicked \(button) at (\(Int(x * scaleX)), \(Int(y * scaleY)))"
            case let .typeText(text):
                "Typed \"\(text)\""
            case let .keyPress(key, modifiers):
                // Mirror the live "Pressed <key> with mod+mod" shape so
                // stub routing assertions cover the modifier contract too.
                modifiers.isEmpty
                    ? "Pressed \(key)"
                    : "Pressed \(key) with \(modifiers.map(\.rawValue).joined(separator: "+"))"
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

    /// Test-owned mirror of the live shortcut table shape: modified a-z and 0-9 plus named keys
    /// resolve, while punctuation like "!" has no slot.
    private func isShortcutMappable(_ key: String) -> Bool {
        Self.keyCode(for: key) != nil
    }
}

// MARK: - Test Suite

@Suite("Desktop Tools", .serialized)
struct DesktopToolsTests {
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
    func `Builtin registration ships both desktop tools disabled`() async throws {
        // Boot-path contract: every tool registers, non-desktop tools stay
        // enabled, and desktop tools arrive disabled until the restore path
        // re-applies persisted rows with no config gate.
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let bus = ToolBus()
        try await BuiltinToolPlugins.registerAll(on: bus, policyStore: policyStore)

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

    // MARK: - UTF-16 typing units and scroll delta bounds

    #if canImport(CoreGraphics) && canImport(AppKit)
        @Test
        func `unicodeCodeUnits maps an emoji to a surrogate pair and ASCII to one unit`() {
            // Non-BMP scalars must post as UTF-16 surrogate pairs; a raw 32-bit
            // scalar value truncated to 16 bits traps inside CGEvent posting.
            let emoji = DesktopControlBridge.unicodeCodeUnits(for: "🎉")
            #expect(emoji.count == 2)
            #expect(emoji == [0xD83C, 0xDF89])
            #expect(DesktopControlBridge.unicodeCodeUnits(for: "a") == [0x61])
        }
    #endif

    @Test
    func `validateScrollDeltas accepts deltas at the posting bound`() throws {
        try DesktopControlBridge.validateScrollDeltas([
            .typeText(text: "unaffected"),
            .scroll(deltaX: 100_000, deltaY: -100_000)
        ])
    }

    @Test
    func `validateScrollDeltas rejects oversized deltas with the offending index`() {
        do {
            try DesktopControlBridge.validateScrollDeltas([
                .delay(milliseconds: 10),
                .scroll(deltaX: 0, deltaY: -100_001)
            ])
            Issue.record("Oversized scroll delta must fail preflight")
        } catch let error as DesktopControlError {
            guard case let .actionFailed(index, reason) = error else {
                Issue.record("Expected actionFailed, got \(error)")
                return
            }
            #expect(index == 1)
            #expect(reason.contains("100001"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func `Oversized scroll deltas fail preflight before any dispatch`() async throws {
        // The bound must refuse through executeBatch itself, before CGEvent work,
        // even when Accessibility is fully granted.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let live = DesktopControlBridge(accessibilityAccess: { true })
        do {
            _ = try await live.executeBatch(
                actions: [.scroll(deltaX: 150_001, deltaY: 0)],
                scaleX: 1.0,
                scaleY: 1.0,
                blockedApps: []
            )
            Issue.record("Oversized scroll delta must be refused in preflight")
        } catch let error as DesktopControlError {
            guard case let .actionFailed(index, reason) = error else {
                Issue.record("Expected actionFailed, got \(error)")
                return
            }
            #expect(index == 0)
            #expect(reason.contains("150001"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        await DesktopControlMonitor.shared.clearEmergencyStop()
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
        // Exercises the real fail-closed gate with an injected denial so the test proves the bridge
        // itself refuses before touching shareable content, rather than trusting the stub to throw
        // on its behalf.
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
        // Same hermetic pattern as the capture gate: the live bridge with a denied silent check
        // must refuse before validating the batch or reaching CGEvent dispatch.
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
        // Ordering contract: an operator stop latched before the first step aborts without paying a
        // TCC syscall, so a stopped turn never reports a permission error instead of the stop.
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
        // Same ordering contract for task cancellation: a cancelled turn must surface cancellation
        // rather than masking it behind a permission error that would invite a pointless Settings
        // trip.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let denied = DesktopControlBridge(accessibilityAccess: { false })
        // Gate the batch behind a signal the test opens only after cancelling, so `executeBatch`
        // always begins with cancellation latched.
        let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for await _ in gate {
                break
            }
            return try await denied.executeBatch(
                actions: [.delay(milliseconds: 10)],
                scaleX: 1.0,
                scaleY: 1.0,
                blockedApps: []
            )
        }
        task.cancel()
        gateContinuation.yield()
        gateContinuation.finish()
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
        // Fail-closed list contract: a denied window scan fails the turn with permission guidance
        // so the model can tell "no permission" apart from "no windows"; an empty success still
        // means a genuine scan found nothing.
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

    // MARK: - Shortcut key_press batches (hermetic stub routing)

    @Test
    func `Cmd Shift H routes through stub shortcut path`() async throws {
        // Modified letters must reach the shortcut system as hardware codes (h is 0x04) instead of
        // Unicode text, since Unicode posting with command flags never triggers the intended chord.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let tool = DesktopActionTool(controlBridge: StubDesktopControlBridge())
        let input = ToolInput(
            toolName: "desktop.action",
            argumentsJSON: #"{"actions": [{"action": "key_press", "key": "h", "modifiers": ["cmd", "shift"]}]}"#
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(!output.isError)
        #expect(output.content.contains("Pressed h"))
        #expect(output.content.contains("cmd"))
        #expect(output.content.contains("shift"))
        await DesktopControlMonitor.shared.clearEmergencyStop()
    }

    @Test
    func `Cmd Shift N routes through stub shortcut path`() async throws {
        // Same hardware-code invariant for the companion Finder chord
        // (n is 0x2D): modified input must resolve before any Unicode path.
        // Stubbed so CI never dispatches the live chord.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let tool = DesktopActionTool(controlBridge: StubDesktopControlBridge())
        let input = ToolInput(
            toolName: "desktop.action",
            argumentsJSON: #"{"actions": [{"action": "key_press", "key": "n", "modifiers": ["cmd", "shift"]}]}"#
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(!output.isError)
        #expect(output.content.contains("Pressed n"))
        #expect(output.content.contains("cmd"))
        #expect(output.content.contains("shift"))
        await DesktopControlMonitor.shared.clearEmergencyStop()
    }

    @Test
    func `Uppercase H with Cmd matches lowercase shortcut`() async throws {
        // Lookup folds case so Shift-as-capitalization never forks the
        // chord: explicit cmd plus uppercase H lands on the same hardware
        // key as lowercase h instead of typing a literal.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let tool = DesktopActionTool(controlBridge: StubDesktopControlBridge())
        let context = ToolContext(conversationID: UUID())
        let lower = try await tool.execute(
            input: ToolInput(
                toolName: "desktop.action",
                argumentsJSON: #"{"actions": [{"action": "key_press", "key": "h", "modifiers": ["cmd"]}]}"#
            ),
            context: context
        )
        let upper = try await tool.execute(
            input: ToolInput(
                toolName: "desktop.action",
                argumentsJSON: #"{"actions": [{"action": "key_press", "key": "H", "modifiers": ["cmd"]}]}"#
            ),
            context: context
        )
        #expect(!lower.isError)
        #expect(!upper.isError)
        #expect(lower.content.contains("Pressed h"))
        #expect(upper.content.contains("Pressed H"))
        await DesktopControlMonitor.shared.clearEmergencyStop()
    }

    @Test
    func `Bare N without modifiers takes the stub typing path`() async throws {
        // Unmodified characters stay layout-exact through Unicode posting
        // rather than consuming a hardware slot, so plain typing never
        // depends on the shortcut table. Stubbed to avoid live dispatch.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let tool = DesktopActionTool(controlBridge: StubDesktopControlBridge())
        let input = ToolInput(
            toolName: "desktop.action",
            argumentsJSON: #"{"actions": [{"action": "key_press", "key": "n"}]}"#
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(!output.isError)
        #expect(output.content.contains("Pressed n"))
        await DesktopControlMonitor.shared.clearEmergencyStop()
    }

    @Test
    func `Modified punctuation fails closed as unknown key`() async throws {
        // Punctuation has no shortcut hardware slot, so a modified mark must refuse with guidance
        // instead of typing a literal that the model would mistake for a successful chord.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let tool = DesktopActionTool(controlBridge: StubDesktopControlBridge())
        let input = ToolInput(
            toolName: "desktop.action",
            argumentsJSON: #"{"actions": [{"action": "key_press", "key": "!", "modifiers": ["cmd"]}]}"#
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError)
        #expect(output.content.contains("Unknown key name"))
        // The denial must carry the live hint verbatim so stub and live
        // failures give the operator identical recovery guidance.
        #expect(output.content.contains("Return/Enter, Escape/Esc"))
        await DesktopControlMonitor.shared.clearEmergencyStop()
    }

    @Test
    func `Shortcut hardware codes match documented values`() {
        // Pins the chord contract without posting: modified input must resolve to the physical key
        // the shortcut system expects, so the suite locks representative codes plus full-table
        // coverage and case folding instead of trusting routing text alone.
        #expect(StubDesktopControlBridge.keyCode(for: "h") == 0x04)
        #expect(StubDesktopControlBridge.keyCode(for: "H") == 0x04)
        #expect(StubDesktopControlBridge.keyCode(for: "n") == 0x2D)
        #expect(StubDesktopControlBridge.keyCode(for: "N") == 0x2D)
        #expect(StubDesktopControlBridge.keyCode(for: "a") == 0x00)
        #expect(StubDesktopControlBridge.keyCode(for: "z") == 0x06)
        #expect(StubDesktopControlBridge.keyCode(for: "0") == 0x1D)
        #expect(StubDesktopControlBridge.keyCode(for: "9") == 0x19)
        #expect(StubDesktopControlBridge.keyCode(for: "return") == 0x24)
        #expect(StubDesktopControlBridge.keyCode(for: "Enter") == 0x24)
        #expect(StubDesktopControlBridge.keyCode(for: "escape") == 0x35)
        #expect(StubDesktopControlBridge.keyCode(for: "Esc") == 0x35)
        #expect(StubDesktopControlBridge.keyCode(for: "tab") == 0x30)
        #expect(StubDesktopControlBridge.keyCode(for: "space") == 0x31)
        #expect(StubDesktopControlBridge.keyCode(for: "backspace") == 0x33)
        #expect(StubDesktopControlBridge.keyCode(for: "delete") == 0x33)
        #expect(StubDesktopControlBridge.keyCode(for: "arrowup") == 0x7E)
        #expect(StubDesktopControlBridge.keyCode(for: "arrowdown") == 0x7D)
        #expect(StubDesktopControlBridge.keyCode(for: "arrowleft") == 0x7B)
        #expect(StubDesktopControlBridge.keyCode(for: "arrowright") == 0x7C)
        #expect(StubDesktopControlBridge.keyCode(for: "home") == 0x73)
        #expect(StubDesktopControlBridge.keyCode(for: "end") == 0x77)
        #expect(StubDesktopControlBridge.keyCode(for: "pageup") == 0x74)
        #expect(StubDesktopControlBridge.keyCode(for: "pagedown") == 0x79)
        #expect(StubDesktopControlBridge.keyCode(for: "f1") == 0x7A)
        #expect(StubDesktopControlBridge.keyCode(for: "F12") == 0x6F)
        // Every letter and digit resolves, while punctuation and unknown
        // names have no slot and must fail closed as unknown keys.
        for scalar in "abcdefghijklmnopqrstuvwxyz0123456789" {
            #expect(StubDesktopControlBridge.keyCode(for: String(scalar)) != nil)
        }
        #expect(StubDesktopControlBridge.keyCode(for: "!") == nil)
        #expect(StubDesktopControlBridge.keyCode(for: "@") == nil)
        #expect(StubDesktopControlBridge.keyCode(for: ".") == nil)
        #expect(StubDesktopControlBridge.keyCode(for: "F13") == nil)
        #expect(StubDesktopControlBridge.keyCode(for: "") == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNEWEAVER_LIVE_DESKTOP_SHORTCUTS"] == "1"))
    func `Live shortcut dispatch runs only with explicit opt-in`() async throws {
        // Live CGEvent dispatch stays behind an explicit opt-in so the unit suite never posts real
        // Finder chords on macOS CI; set RUNEWEAVER_LIVE_DESKTOP_SHORTCUTS=1 for a local integration
        // run.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let live = DesktopControlBridge(accessibilityAccess: { true })
        do {
            let results = try await live.executeBatch(
                actions: [.keyPress(key: "h", modifiers: [.cmd, .shift])],
                scaleX: 1.0,
                scaleY: 1.0,
                blockedApps: []
            )
            #expect(results.count == 1)
            #expect(results[0].success == true)
            #expect(results[0].message.contains("Pressed h"))
        } catch let error as DesktopControlError {
            #if canImport(CoreGraphics) && canImport(AppKit)
                Issue.record("Live cmd+shift+h should resolve to 0x04, got \(error)")
            #else
                #expect(error == .unsupportedPlatform)
            #endif
        } catch {
            Issue.record("Unexpected failure for live cmd+shift+h: \(error)")
        }
        await DesktopControlMonitor.shared.clearEmergencyStop()
    }

    @Test
    func `Nine-step Finder batch decodes and keeps envelope shape`() async throws {
        // The reported Finder flow mixes app focus, shortcut chords, typing, and pointer settles;
        // the batch must decode intact and the tool envelope must report the full shape so progress
        // stays honest.
        await DesktopControlMonitor.shared.clearEmergencyStop()
        let json = """
        {
            "actions": [
                {"action": "switch_app", "app_name": "Finder"},
                {"action": "key_press", "key": "h", "modifiers": ["cmd", "shift"]},
                {"action": "key_press", "key": "n", "modifiers": ["cmd", "shift"]},
                {"action": "type_text", "text": "Untitled folder"},
                {"action": "key_press", "key": "Return"},
                {"action": "click", "x": 400, "y": 300},
                {"action": "double_click", "x": 400, "y": 300},
                {"action": "scroll", "delta_x": 0, "delta_y": -20},
                {"action": "delay", "milliseconds": 200}
            ],
            "scale_x": 1.0,
            "scale_y": 1.0
        }
        """
        let decoded = try DesktopActionArgs.decode(from: json)
        #expect(decoded.actions.count == 9)

        let tool = DesktopActionTool(controlBridge: StubDesktopControlBridge())
        let input = ToolInput(toolName: "desktop.action", argumentsJSON: json)
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(!output.isError)
        let data = try #require(output.content.data(using: .utf8))
        let envelope = try JSONDecoder().decode(DesktopActionEnvelope.self, from: data)
        #expect(envelope.success == true)
        #expect(envelope.stepsTotal == 9)
        #expect(envelope.stepsCompleted == 9)
        #expect(envelope.results.count == 9)
        await DesktopControlMonitor.shared.clearEmergencyStop()
    }
}
