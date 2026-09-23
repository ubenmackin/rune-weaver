// Rune Weaver Tools — Desktop vision and control tools (`desktop.screenshot`, `desktop.action`).
//
// `desktop.screenshot` is read-only and safe: it captures the screen or a
// specific window, downscales the image, and returns it with coordinate
// metadata and an optional window list.
//
// `desktop.action` is approval-gated and dangerous: it dispatches batched
// mouse, keyboard, and app-switch actions through the permission gate.
// Both tools always register so they stay visible in `GET /tools`, but
// boot registration ships them disabled and the persisted tool-state toggle
// is the sole authority for enablement, so neither runs without an explicit
// operator action.

import Foundation
import RuneWeaverCore

// MARK: - Screenshot tool

/// Read-only desktop screenshot tool for vision models.
public struct DesktopScreenshotTool: Tool, Sendable {
    public let name = "desktop.screenshot"
    public let description =
        "Captures a screenshot of the macOS desktop or a specific app window; returns a downscaled JPEG "
            + "with coordinate metadata for desktop.action and an optional list of visible windows."
    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"#
            + #""display":{"type":"integer","#
            + #""description":"Display index to capture (0 = main). Omit to capture the main display.","#
            + #""default":0},"#
            + #""target_app":{"type":"string","#
            + #""description":"Name of a running application to capture its frontmost window instead of the full display."},"#
            + #""include_windows_list":{"type":"boolean","#
            + #""description":"Include a list of all visible windows in the output.","default":false}"#
            + #"},"additionalProperties":false}"#
    )
    public let permissionLevel = PermissionLevel.readOnly

    private let captureBridge: any DesktopCapturing
    private let maxDimension: Int
    private let jpegQuality: Double

    /// Creates the screenshot tool.
    /// - Parameters:
    ///   - captureBridge: Capture implementation (live by default, stub for tests).
    ///   - maxDimension: Longest edge bound for the downscaled image.
    ///   - jpegQuality: JPEG compression quality (0.0–1.0).
    public init(
        captureBridge: any DesktopCapturing = DesktopCaptureBridge(),
        maxDimension: Int = DesktopConfig.defaultMaxImageDimension,
        jpegQuality: Double = DesktopConfig.defaultJpegQuality
    ) {
        self.captureBridge = captureBridge
        self.maxDimension = maxDimension
        self.jpegQuality = jpegQuality
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args = try DesktopScreenshotArgs.decode(from: input.argumentsJSON)

        let result: DesktopCaptureResult
        if let targetApp = args.targetApp, !targetApp.isEmpty {
            do {
                result = try await captureBridge.captureWindow(
                    appName: targetApp,
                    maxDimension: maxDimension,
                    jpegQuality: jpegQuality
                )
            } catch let error as DesktopCaptureError {
                return .failure(friendlyError(error))
            }
        } else {
            do {
                result = try await captureBridge.captureDisplay(
                    displayIndex: args.display,
                    maxDimension: maxDimension,
                    jpegQuality: jpegQuality
                )
            } catch let error as DesktopCaptureError {
                return .failure(friendlyError(error))
            }
        }

        var windows: [DesktopWindowInfo]?
        if args.includeWindowsList {
            // A denied window list fails the turn with permission guidance
            // instead of silently omitting windows; an empty success still
            // means the scan genuinely found nothing.
            do {
                windows = try await captureBridge.listWindows()
            } catch let error as DesktopCaptureError {
                return .failure(friendlyError(error))
            }
        }

        let envelope = DesktopScreenshotEnvelope(
            screenshotDataURL: result.screenshotDataURL,
            screenshotHash: result.screenshotHash,
            originalWidth: result.originalWidth,
            originalHeight: result.originalHeight,
            scaledWidth: result.scaledWidth,
            scaledHeight: result.scaledHeight,
            scaleX: result.scaleX,
            scaleY: result.scaleY,
            displayIndex: result.displayIndex,
            targetApp: result.targetApp,
            windows: windows
        )
        let content = try ToolEnvelopeEncoding.encode(envelope)
        return .success(content)
    }

    private func friendlyError(_ error: DesktopCaptureError) -> String {
        switch error {
        case .screenRecordingPermissionDenied:
            // Fail-closed guidance: keep the short grant sentence, then give
            // the operator the exact recovery path plus relaunch and prompt
            // behavior, so a denied turn explains how to unblock without guessing.
            "Screen Recording permission is required. Grant it in System Settings > Privacy & Security > Screen Recording for this application. "
                + "To enable: open System Settings > Privacy & Security > Screen Recording, toggle the app/terminal on, then quit + relaunch the app. "
                + "macOS auto-prompts on first capture so no manual add step is needed."
        case let .displayNotFound(index):
            "Display \(index) not found. Use display index 0 for the main display."
        case let .windowNotFound(appName):
            "No visible window found for '\(appName)'. Check that the application is running and has a window open."
        case let .captureFailed(reason):
            "Screenshot capture failed: \(reason)"
        case .unsupportedPlatform:
            "Desktop screenshot is only supported on macOS."
        }
    }
}

// MARK: - Action tool

/// Approval-gated desktop control tool for mouse, keyboard, and app switching.
public struct DesktopActionTool: Tool, Sendable {
    public let name = "desktop.action"
    public let description =
        "Executes batched macOS desktop actions (switch_app, click, type_text, key_press, mouse_move, "
            + "double_click, drag, scroll, delay); approval-gated, disabled by default."
    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"#
            + #""actions":{"type":"array","#
            + #""description":"Array of action objects to execute sequentially. Max 20 per batch.","#
            + #""items":{"type":"object","properties":{"#
            + #""action":{"type":"string","enum":["switch_app","click","double_click","mouse_move","#
            + #""drag","type_text","key_press","scroll","delay"]},"#
            + #""app_name":{"type":"string","description":"For switch_app: application name to activate."},"#
            + #""x":{"type":"number","description":"For click/double_click/mouse_move: x coordinate in screenshot pixel space."},"#
            + #""y":{"type":"number","description":"For click/double_click/mouse_move: y coordinate in screenshot pixel space."},"#
            + #""button":{"type":"string","enum":["left","right"],"default":"left","description":"For click: mouse button."},"#
            + #""modifiers":{"type":"array","items":{"type":"string","enum":["cmd","shift","alt","ctrl"]},"#
            + #""description":"Keyboard modifiers to hold."},"#
            + #""from_x":{"type":"number","description":"For drag: start x."},"#
            + #""from_y":{"type":"number","description":"For drag: start y."},"#
            + #""to_x":{"type":"number","description":"For drag: end x."},"#
            + #""to_y":{"type":"number","description":"For drag: end y."},"#
            + #""text":{"type":"string","maxLength":2000,"description":"For type_text: the text string to type (max 2000 characters)."},"#
            + #""key":{"type":"string","#
            + #""description":"For key_press: key name (Return, Escape, Tab, Space, Backspace, ArrowUp/Down/Left/Right, F1-F12, or a character)."},"#
            + #""delta_x":{"type":"integer","description":"For scroll: horizontal scroll amount.","default":0},"#
            + #""delta_y":{"type":"integer","description":"For scroll: vertical scroll amount (negative = up).","default":0},"#
            + #""milliseconds":{"type":"integer","description":"For delay: pause duration in ms (max 5000).","default":200}"#
            + #"},"required":["action"]},"minItems":1,"maxItems":20},"#
            + #""scale_x":{"type":"number","#
            + #""description":"Horizontal scale factor from screenshot coordinates to native.","default":1.0},"#
            + #""scale_y":{"type":"number","#
            + #""description":"Vertical scale factor from screenshot coordinates to native.","default":1.0}"#
            + #"},"required":["actions"],"additionalProperties":false}"#
    )
    public let permissionLevel = PermissionLevel.requiresApproval

    private let controlBridge: any DesktopControlling
    private let blockedApps: [String]

    /// Creates the action tool.
    /// - Parameters:
    ///   - controlBridge: Control implementation (live by default, stub for tests).
    ///   - blockedApps: Application names to block from receiving input.
    public init(
        controlBridge: any DesktopControlling = DesktopControlBridge(),
        blockedApps: [String] = DesktopConfig.defaultBlockedApps
    ) {
        self.controlBridge = controlBridge
        self.blockedApps = blockedApps
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args = try DesktopActionArgs.decode(from: input.argumentsJSON)

        // Mark the batch active so the menu-bar indicator and Emergency Stop
        // appear for exactly the window the bridge is dispatching input.
        await DesktopControlMonitor.shared.beginBatch()
        do {
            let results = try await controlBridge.executeBatch(
                actions: args.actions,
                scaleX: args.scaleX,
                scaleY: args.scaleY,
                blockedApps: blockedApps
            )
            await DesktopControlMonitor.shared.endBatch()
            let envelope = DesktopActionEnvelope(
                success: true,
                stepsCompleted: results.count,
                stepsTotal: args.actions.count,
                results: results,
                error: nil
            )
            let content = try ToolEnvelopeEncoding.encode(envelope)
            return .success(content)
        } catch let error as DesktopControlError {
            await DesktopControlMonitor.shared.endBatch()
            return .failure(friendlyError(error))
        } catch is CancellationError {
            await DesktopControlMonitor.shared.endBatch()
            return .failure(friendlyError(.emergencyStopped))
        } catch {
            await DesktopControlMonitor.shared.endBatch()
            throw error
        }
    }

    private func friendlyError(_ error: DesktopControlError) -> String {
        switch error {
        case let .blockedApp(appName):
            "SAFETY: '\(appName)' is on the blocked-app list and cannot receive automated input. "
                + "This protects sensitive apps from unintended actions."
        case .accessibilityPermissionDenied:
            // Fail-closed guidance: keep the short grant sentence, then give
            // the operator the exact recovery path plus why control needs it,
            // so a denied turn explains how to unblock without prompting again.
            "Accessibility permission is required. Grant it in System Settings > Privacy & Security > Accessibility for this application. "
                + "To enable: open System Settings > Privacy & Security > Accessibility, toggle the app/terminal on, then quit + relaunch the app. "
                + "Desktop control drives the mouse and keyboard via CGEvent, which macOS blocks until approval is granted."
        case .failSafeTriggered:
            "FAIL-SAFE TRIGGERED: Mouse cursor was detected in a screen corner. "
                + "All desktop actions have been aborted. Move the cursor away from corners to resume."
        case .emergencyStopped:
            "EMERGENCY STOP: Desktop automation was aborted by the operator. "
                + "No further actions were dispatched."
        case .unsupportedPlatform:
            "Desktop control is only supported on macOS."
        case let .actionFailed(index, reason):
            "Action at step \(index) failed: \(reason)"
        case let .batchTooLarge(count, max):
            "Batch too large: \(count) actions submitted, maximum is \(max). Split into smaller batches."
        }
    }
}

// MARK: - Argument types

struct DesktopScreenshotArgs: Codable {
    let display: Int
    let targetApp: String?
    let includeWindowsList: Bool

    private enum CodingKeys: String, CodingKey {
        case display
        case targetApp = "target_app"
        case includeWindowsList = "include_windows_list"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        display = try container.decodeIfPresent(Int.self, forKey: .display) ?? 0
        targetApp = try container.decodeIfPresent(String.self, forKey: .targetApp)
        includeWindowsList = try container.decodeIfPresent(Bool.self, forKey: .includeWindowsList) ?? false
    }

    static func decode(from json: String) throws -> DesktopScreenshotArgs {
        let data = json.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode(DesktopScreenshotArgs.self, from: data)
    }
}

struct DesktopActionArgs: Codable {
    let actions: [DesktopAction]
    let scaleX: Double
    let scaleY: Double

    private enum CodingKeys: String, CodingKey {
        case actions
        case scaleX = "scale_x"
        case scaleY = "scale_y"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decode([DesktopAction].self, forKey: .actions)
        scaleX = try container.decodeIfPresent(Double.self, forKey: .scaleX) ?? 1.0
        scaleY = try container.decodeIfPresent(Double.self, forKey: .scaleY) ?? 1.0
    }

    static func decode(from json: String) throws -> DesktopActionArgs {
        let data = json.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode(DesktopActionArgs.self, from: data)
    }
}

// MARK: - Output envelopes

/// Output envelope for `desktop.screenshot`.
public struct DesktopScreenshotEnvelope: Sendable, Codable, Equatable {
    public let screenshotDataURL: String
    public let screenshotHash: String
    public let originalWidth: Int
    public let originalHeight: Int
    public let scaledWidth: Int
    public let scaledHeight: Int
    public let scaleX: Double
    public let scaleY: Double
    public let displayIndex: Int
    public let targetApp: String?
    public let windows: [DesktopWindowInfo]?

    private enum CodingKeys: String, CodingKey {
        case screenshotDataURL
        case screenshotHash
        case originalWidth
        case originalHeight
        case scaledWidth
        case scaledHeight
        case scaleX
        case scaleY
        case displayIndex
        case targetApp
        case windows
    }

    /// Copy safe for durable history with transient pixels removed.
    /// Keeps the content hash plus dimensions and scales so the audit trail
    /// can correlate the capture without retaining recoverable pixels.
    public func strippedForPersistence() -> DesktopScreenshotEnvelope {
        DesktopScreenshotEnvelope(
            screenshotDataURL: VisionGate.strippedPlaceholder,
            screenshotHash: screenshotHash,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            scaledWidth: scaledWidth,
            scaledHeight: scaledHeight,
            scaleX: scaleX,
            scaleY: scaleY,
            displayIndex: displayIndex,
            targetApp: targetApp,
            windows: windows
        )
    }

    /// Parses a raw tool output document, returning nil for non-desktop payloads.
    public static func parse(_ content: String) -> DesktopScreenshotEnvelope? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DesktopScreenshotEnvelope.self, from: data),
              !decoded.screenshotHash.isEmpty
        else { return nil }
        return decoded
    }

    /// Redacts screenshot pixels from raw tool content for durable storage.
    /// Decodes the envelope when present and re-encodes the stripped copy so
    /// run logs, message history, and episodic records keep the hash plus
    /// dimensions and scales; other payloads fall back to the shared vision
    /// gate so inline data URLs never reach disk. The live turn keeps the
    /// full data URL in memory.
    public static func redactedForPersistence(_ content: String) -> String {
        if let envelope = parse(content),
           let data = try? ToolEnvelopeEncoding.encode(envelope.strippedForPersistence())
        {
            return data
        }
        return VisionGate.strippedContent(content)
    }
}

/// Output envelope for `desktop.action`.
public struct DesktopActionEnvelope: Sendable, Codable, Equatable {
    public let success: Bool
    public let stepsCompleted: Int
    public let stepsTotal: Int
    public let results: [DesktopActionStepResult]
    public let error: String?
}

// MARK: - Factory

/// Factory registering the LLM-invokable desktop tools on a `ToolBus`.
public enum DesktopTools {
    /// Tool names in registration order.
    public static let screenshotToolName = "desktop.screenshot"
    public static let actionToolName = "desktop.action"

    /// Both tool names in registration order, regardless of config.
    public static var allToolNames: [String] {
        [screenshotToolName, actionToolName]
    }

    /// Builds the desktop tools according to the configuration.
    ///
    /// Both tools always register — visibility in `GET /tools` never
    /// depends on a toggle, so the surface stays inspectable instead of
    /// shape-shifting. Enablement is governed solely by the persisted
    /// tool-state toggle: boot-path callers register them disabled
    /// (`isEnabled: false`), stored rows restore operator intent, and no
    /// config gate overrides that state.
    /// - Parameters:
    ///   - desktopConfig: The `[desktop]` configuration section carrying
    ///     capture knobs (dimensions, quality, blocklist).
    ///   - captureBridge: Optional capture bridge (for tests).
    ///   - controlBridge: Optional control bridge (for tests).
    /// - Returns: Both desktop tools, in registration order.
    public static func makeTools(
        desktopConfig: DesktopConfig = DesktopConfig(),
        captureBridge: (any DesktopCapturing)? = nil,
        controlBridge: (any DesktopControlling)? = nil
    ) -> [any Tool] {
        [
            DesktopScreenshotTool(
                captureBridge: captureBridge ?? DesktopCaptureBridge(),
                maxDimension: desktopConfig.maxImageDimension,
                jpegQuality: desktopConfig.jpegQuality
            ),
            DesktopActionTool(
                controlBridge: controlBridge ?? DesktopControlBridge(),
                blockedApps: desktopConfig.blockedApps
            )
        ]
    }

    /// Both tool names in registration order; registration itself never
    /// depends on config — the tool-state toggle is the sole authority.
    public static func toolNames(for _: DesktopConfig) -> [String] {
        allToolNames
    }

    /// Requests desktop TCC trust for an explicit enable toggle.
    ///
    /// Why a separate requesting path: the system dialogs take focus and
    /// would derail an autonomous turn, so tool execution stays on the
    /// silent checks and only the enable UI calls here in direct response
    /// to the operator flipping desktop tools on. Each return reflects
    /// trust at call time; the operator grants in Settings and relaunches
    /// before the next turn re-checks silently.
    /// - Returns: Trust at call time for capture and control, respectively.
    @MainActor
    public static func requestPermissionsForEnable() -> (
        screenRecordingGranted: Bool, accessibilityGranted: Bool
    ) {
        let screenRecordingGranted = DesktopCaptureBridge.requestScreenRecordingAccess()
        let accessibilityGranted = DesktopPermissionCheck.requestAccessibilityTrust()
        return (screenRecordingGranted, accessibilityGranted)
    }
}
