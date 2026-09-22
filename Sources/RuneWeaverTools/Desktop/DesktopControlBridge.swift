// Rune Weaver Tools — Desktop control bridge for macOS automation.
//
// Wraps CGEvent and NSWorkspace to provide mouse, keyboard, and app-switching
// primitives. Safety checks enforce a blocked-app list and fail-safe corner
// abort before every dispatched event. Coordinates arrive in the downscaled
// screenshot space and are translated back to native display points using the
// scale factors from `DesktopCaptureResult`.

import Foundation
import RuneWeaverCore

#if canImport(CoreGraphics) && canImport(AppKit)
    import AppKit
    import CoreGraphics
#endif

// MARK: - Action types

/// A single desktop control action the LLM can request.
public enum DesktopAction: Sendable, Codable, Equatable {
    /// Switch focus to the named application.
    case switchApp(appName: String)
    /// Move the mouse cursor without clicking.
    case mouseMove(x: Double, y: Double)
    /// Click at the given position.
    case click(x: Double, y: Double, button: MouseButton, modifiers: [KeyModifier])
    /// Double-click at the given position.
    case doubleClick(x: Double, y: Double, modifiers: [KeyModifier])
    /// Drag from one position to another.
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    /// Type a string of text.
    case typeText(text: String)
    /// Press a special key or key combo.
    case keyPress(key: String, modifiers: [KeyModifier])
    /// Scroll at the current mouse position.
    case scroll(deltaX: Int, deltaY: Int)
    /// Pause for a short duration (milliseconds) to let the UI settle.
    case delay(milliseconds: Int)

    private enum CodingKeys: String, CodingKey {
        case action, appName = "app_name"
        case x, y, button, modifiers
        case fromX = "from_x", fromY = "from_y", toX = "to_x", toY = "to_y"
        case text, key
        case deltaX = "delta_x", deltaY = "delta_y"
        case milliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        switch action {
        case "switch_app":
            let name = try container.decode(String.self, forKey: .appName)
            self = .switchApp(appName: name)
        case "mouse_move":
            let x = try container.decode(Double.self, forKey: .x)
            let y = try container.decode(Double.self, forKey: .y)
            self = .mouseMove(x: x, y: y)
        case "click":
            let x = try container.decode(Double.self, forKey: .x)
            let y = try container.decode(Double.self, forKey: .y)
            let button = try container.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left
            let mods = try container.decodeIfPresent([KeyModifier].self, forKey: .modifiers) ?? []
            self = .click(x: x, y: y, button: button, modifiers: mods)
        case "double_click":
            let x = try container.decode(Double.self, forKey: .x)
            let y = try container.decode(Double.self, forKey: .y)
            let mods = try container.decodeIfPresent([KeyModifier].self, forKey: .modifiers) ?? []
            self = .doubleClick(x: x, y: y, modifiers: mods)
        case "drag":
            let fromX = try container.decode(Double.self, forKey: .fromX)
            let fromY = try container.decode(Double.self, forKey: .fromY)
            let toX = try container.decode(Double.self, forKey: .toX)
            let toY = try container.decode(Double.self, forKey: .toY)
            self = .drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
        case "type_text":
            let text = try container.decode(String.self, forKey: .text)
            self = .typeText(text: text)
        case "key_press":
            let key = try container.decode(String.self, forKey: .key)
            let mods = try container.decodeIfPresent([KeyModifier].self, forKey: .modifiers) ?? []
            self = .keyPress(key: key, modifiers: mods)
        case "scroll":
            let deltaX = try container.decodeIfPresent(Int.self, forKey: .deltaX) ?? 0
            let deltaY = try container.decodeIfPresent(Int.self, forKey: .deltaY) ?? 0
            self = .scroll(deltaX: deltaX, deltaY: deltaY)
        case "delay":
            let delayMs = try container.decodeIfPresent(Int.self, forKey: .milliseconds) ?? 200
            self = .delay(milliseconds: delayMs)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action, in: container,
                debugDescription: "Unknown action type: \(action)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .switchApp(appName):
            try container.encode("switch_app", forKey: .action)
            try container.encode(appName, forKey: .appName)
        case let .mouseMove(x, y):
            try container.encode("mouse_move", forKey: .action)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case let .click(x, y, button, modifiers):
            try container.encode("click", forKey: .action)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(button, forKey: .button)
            if !modifiers.isEmpty {
                try container.encode(modifiers, forKey: .modifiers)
            }
        case let .doubleClick(x, y, modifiers):
            try container.encode("double_click", forKey: .action)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            if !modifiers.isEmpty {
                try container.encode(modifiers, forKey: .modifiers)
            }
        case let .drag(fromX, fromY, toX, toY):
            try container.encode("drag", forKey: .action)
            try container.encode(fromX, forKey: .fromX)
            try container.encode(fromY, forKey: .fromY)
            try container.encode(toX, forKey: .toX)
            try container.encode(toY, forKey: .toY)
        case let .typeText(text):
            try container.encode("type_text", forKey: .action)
            try container.encode(text, forKey: .text)
        case let .keyPress(key, modifiers):
            try container.encode("key_press", forKey: .action)
            try container.encode(key, forKey: .key)
            if !modifiers.isEmpty {
                try container.encode(modifiers, forKey: .modifiers)
            }
        case let .scroll(deltaX, deltaY):
            try container.encode("scroll", forKey: .action)
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
        case let .delay(delayMs):
            try container.encode("delay", forKey: .action)
            try container.encode(delayMs, forKey: .milliseconds)
        }
    }
}

/// Mouse button for click actions.
public enum MouseButton: String, Sendable, Codable, Equatable {
    case left
    case right
}

/// Keyboard modifier for key combos.
public enum KeyModifier: String, Sendable, Codable, Equatable {
    case cmd
    case shift
    case alt
    case ctrl
}

// MARK: - Action result

/// Result of executing one desktop action step.
public struct DesktopActionStepResult: Sendable, Codable, Equatable {
    /// Zero-based index in the batch.
    public let index: Int
    /// The action that was executed.
    public let action: DesktopAction
    /// Whether the step succeeded.
    public let success: Bool
    /// Human-readable description of what happened.
    public let message: String
}

// MARK: - Control errors

/// Errors specific to desktop control.
public enum DesktopControlError: Error, Sendable, Equatable {
    /// The target app is on the blocked list.
    case blockedApp(appName: String)
    /// Accessibility permission not granted.
    case accessibilityPermissionDenied
    /// The fail-safe corner was triggered.
    case failSafeTriggered
    /// The operator requested an emergency stop mid-batch.
    case emergencyStopped
    /// The platform does not support desktop control.
    case unsupportedPlatform
    /// An action in the batch failed.
    case actionFailed(index: Int, reason: String)
    /// The batch was too large.
    case batchTooLarge(count: Int, max: Int)
}

// MARK: - Shared emergency state

/// Shared abort source for in-flight desktop automation.
///
/// The menu-bar app requests a stop here and the control bridge polls it
/// before every step, so an operator can abort a runaway batch mid-flight.
/// Activity counting also drives the menu-bar indicator: it is active while
/// at least one batch holds the monitor.
public actor DesktopControlMonitor {
    /// Process-wide shared instance bridging the menu bar and the tool.
    public static let shared = DesktopControlMonitor()

    /// Batches currently executing.
    private var activeCount = 0
    /// Latched stop request, cleared when the last batch settles.
    private var emergencyStop = false

    /// Creates a monitor.
    public init() {}

    /// Whether any desktop batch is currently executing.
    public var isActive: Bool {
        activeCount > 0
    }

    /// Whether an emergency stop has been requested and not yet consumed.
    public var isEmergencyStopRequested: Bool {
        emergencyStop
    }

    /// Marks one batch started.
    public func beginBatch() {
        activeCount += 1
    }

    /// Marks one batch finished, clearing a latched stop when idle.
    public func endBatch() {
        activeCount = max(0, activeCount - 1)
        if activeCount == 0 {
            emergencyStop = false
        }
    }

    /// Latches an emergency stop consumed by the running batch.
    public func requestEmergencyStop() {
        emergencyStop = true
    }

    /// Clears a latched stop without ending a batch.
    public func clearEmergencyStop() {
        emergencyStop = false
    }

    /// Whether the running batch should abort at the next checkpoint.
    public func shouldAbort() -> Bool {
        emergencyStop
    }
}

// MARK: - Control protocol

/// Protocol for desktop control so tests can inject a stub.
public protocol DesktopControlling: Sendable {
    /// Executes a batch of actions sequentially, aborting on first failure.
    func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String]
    ) async throws -> [DesktopActionStepResult]
}

// MARK: - Live control bridge

/// Live desktop control using CGEvent and NSWorkspace.
public struct DesktopControlBridge: DesktopControlling, Sendable {
    /// Maximum actions allowed in a single batch.
    public static let maxBatchSize = 20
    /// Maximum delay allowed in a single delay action (ms).
    public static let maxDelayMs = 5000
    /// Maximum characters allowed in a single type_text action.
    public static let maxTypeTextLength = 2000
    /// Maximum allowed scale factor from screenshot to native coordinates.
    static let maxScaleFactor: Double = 100.0
    /// Maximum allowed coordinate value in screenshot pixel space.
    static let maxCoordinateValue: Double = 20000.0
    /// Corner margin in points for the fail-safe check.
    static let failSafeCornerMargin: CGFloat = 5.0

    public init() {}

    public func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String]
    ) async throws -> [DesktopActionStepResult] {
        guard !actions.isEmpty else {
            throw DesktopControlError.actionFailed(
                index: 0, reason: "No actions provided: batch must contain at least one action"
            )
        }
        guard actions.count <= Self.maxBatchSize else {
            throw DesktopControlError.batchTooLarge(count: actions.count, max: Self.maxBatchSize)
        }
        guard scaleX.isFinite, scaleY.isFinite,
              scaleX > 0, scaleY > 0,
              scaleX <= Self.maxScaleFactor, scaleY <= Self.maxScaleFactor
        else {
            throw DesktopControlError.actionFailed(
                index: 0, reason: "Invalid scale factors (scale_x: \(scaleX), scale_y: \(scaleY)): must be finite, positive, and at most \(Self.maxScaleFactor)"
            )
        }
        // A stop requested before the first step aborts without dispatching.
        if await DesktopControlMonitor.shared.shouldAbort() {
            throw DesktopControlError.emergencyStopped
        }
        try Task.checkCancellation()

        #if canImport(CoreGraphics) && canImport(AppKit)
            var results: [DesktopActionStepResult] = []
            for (index, action) in actions.enumerated() {
                // Cooperative abort before every action so Emergency Stop
                // preempts the next step instead of running the batch out.
                if await DesktopControlMonitor.shared.shouldAbort() {
                    throw DesktopControlError.emergencyStopped
                }
                try Task.checkCancellation()
                // Fail-safe corner check before every action
                if isMouseInCorner() {
                    throw DesktopControlError.failSafeTriggered
                }

                // Blocked app check before input actions
                if needsInputCheck(action) {
                    try checkBlockedApp(blockedApps: blockedApps)
                }

                // Switch-target guard: focusing a blocked app is itself a
                // state change, so check the target before activating.
                if case let .switchApp(appName) = action {
                    try checkSwitchTarget(appName, blockedApps: blockedApps)
                }

                do {
                    let message = try await executeOne(
                        action: action, scaleX: scaleX, scaleY: scaleY,
                        blockedApps: blockedApps
                    )
                    results.append(DesktopActionStepResult(
                        index: index, action: action, success: true, message: message
                    ))
                } catch is CancellationError {
                    throw DesktopControlError.emergencyStopped
                } catch let controlError as DesktopControlError {
                    // Preserve safety signals verbatim so the tool surfaces
                    // the blocked-app and emergency-stop messages instead of
                    // wrapping them as generic step failures.
                    if controlError == .emergencyStopped {
                        throw controlError
                    }
                    if case .blockedApp = controlError {
                        throw controlError
                    }
                    if case let .actionFailed(_, reason) = controlError {
                        results.append(DesktopActionStepResult(
                            index: index, action: action, success: false,
                            message: reason
                        ))
                        throw DesktopControlError.actionFailed(index: index, reason: reason)
                    }
                    results.append(DesktopActionStepResult(
                        index: index, action: action, success: false,
                        message: controlError.localizedDescription
                    ))
                    throw DesktopControlError.actionFailed(
                        index: index, reason: controlError.localizedDescription
                    )
                } catch {
                    results.append(DesktopActionStepResult(
                        index: index, action: action, success: false,
                        message: error.localizedDescription
                    ))
                    throw DesktopControlError.actionFailed(
                        index: index, reason: error.localizedDescription
                    )
                }
            }
            return results
        #else
            throw DesktopControlError.unsupportedPlatform
        #endif
    }
}

// MARK: - Private implementation

#if canImport(CoreGraphics) && canImport(AppKit)

    extension DesktopControlBridge {
        /// Whether an action needs a blocked-app check (input actions only).
        private func needsInputCheck(_ action: DesktopAction) -> Bool {
            switch action {
            case .switchApp, .delay:
                false
            case .mouseMove, .click, .doubleClick, .drag, .typeText, .keyPress, .scroll:
                true
            }
        }

        /// Checks if the frontmost app is on the blocklist.
        private func checkBlockedApp(blockedApps: [String]) throws {
            guard let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName else { return }
            let loweredFront = frontApp.lowercased()
            for blocked in blockedApps where loweredFront == blocked.lowercased() {
                throw DesktopControlError.blockedApp(appName: frontApp)
            }
        }

        /// Rejects a switch_app target that matches the blocked-app list.
        /// Uses the same case-insensitive substring matching as `switchToApp`
        /// so an abbreviated target that would focus a sensitive app is
        /// refused before activation.
        private func checkSwitchTarget(_ target: String, blockedApps: [String]) throws {
            let loweredTarget = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !loweredTarget.isEmpty else { return }
            for blocked in blockedApps {
                let loweredBlocked = blocked.lowercased()
                guard !loweredBlocked.isEmpty else { continue }
                if loweredTarget == loweredBlocked
                    || loweredBlocked.contains(loweredTarget)
                    || loweredTarget.contains(loweredBlocked)
                {
                    throw DesktopControlError.blockedApp(appName: target)
                }
            }
        }

        /// Checks if the mouse cursor is in any screen corner (fail-safe).
        func isMouseInCorner() -> Bool {
            let mouseLocation = NSEvent.mouseLocation
            for screen in NSScreen.screens {
                let frame = screen.frame
                let margin = Self.failSafeCornerMargin
                let corners: [(CGFloat, CGFloat)] = [
                    (frame.minX, frame.minY),
                    (frame.minX, frame.maxY),
                    (frame.maxX, frame.minY),
                    (frame.maxX, frame.maxY)
                ]
                for (cornerX, cornerY) in corners {
                    if abs(mouseLocation.x - cornerX) <= margin, abs(mouseLocation.y - cornerY) <= margin {
                        return true
                    }
                }
            }
            return false
        }

        /// Executes a single action, returning a human-readable result message.
        private func executeOne(
            action: DesktopAction,
            scaleX: Double,
            scaleY: Double,
            blockedApps: [String]
        ) async throws -> String {
            switch action {
            case let .switchApp(appName):
                return try switchToApp(appName, blockedApps: blockedApps)
            case let .mouseMove(x, y):
                let native = try validatedNativePoint(x: x, y: y, scaleX: scaleX, scaleY: scaleY)
                moveMouse(to: native)
                return "Moved cursor to (\(Int(native.x)), \(Int(native.y)))"
            case let .click(x, y, button, modifiers):
                let native = try validatedNativePoint(x: x, y: y, scaleX: scaleX, scaleY: scaleY)
                performClick(at: native, button: button, modifiers: modifiers)
                return "Clicked \(button.rawValue) at (\(Int(native.x)), \(Int(native.y)))"
            case let .doubleClick(x, y, modifiers):
                let native = try validatedNativePoint(x: x, y: y, scaleX: scaleX, scaleY: scaleY)
                performDoubleClick(at: native, modifiers: modifiers)
                return "Double-clicked at (\(Int(native.x)), \(Int(native.y)))"
            case let .drag(fromX, fromY, toX, toY):
                let from = try validatedNativePoint(x: fromX, y: fromY, scaleX: scaleX, scaleY: scaleY)
                let to = try validatedNativePoint(x: toX, y: toY, scaleX: scaleX, scaleY: scaleY)
                performDrag(from: from, to: to)
                return "Dragged from (\(Int(from.x)), \(Int(from.y))) to (\(Int(to.x)), \(Int(to.y)))"
            case let .typeText(text):
                guard text.count <= Self.maxTypeTextLength else {
                    throw NSError(
                        domain: "DesktopControl", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "type_text exceeds maximum length of \(Self.maxTypeTextLength) characters (got \(text.count))"]
                    )
                }
                try await typeString(text)
                let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
                return "Typed \(text.count) characters: \"\(preview)\""
            case let .keyPress(key, modifiers):
                try pressKey(key, modifiers: modifiers)
                let modStr = modifiers.isEmpty ? "" : " with \(modifiers.map(\.rawValue).joined(separator: "+"))"
                return "Pressed \(key)\(modStr)"
            case let .scroll(deltaX, deltaY):
                performScroll(deltaX: Int32(deltaX), deltaY: Int32(deltaY))
                return "Scrolled (dx: \(deltaX), dy: \(deltaY))"
            case let .delay(delayMs):
                let clamped = min(max(0, delayMs), Self.maxDelayMs)
                // Sleep honors Task cancellation; the abort flag covers the
                // menu-bar stop when the turn itself was not cancelled.
                try await Task.sleep(for: .milliseconds(clamped))
                try Task.checkCancellation()
                if await DesktopControlMonitor.shared.shouldAbort() {
                    throw DesktopControlError.emergencyStopped
                }
                return "Waited \(clamped) ms"
            }
        }

        /// Converts downscaled image coordinates to native display points.
        /// Rejects non-finite, negative, or unreasonably large coordinates
        /// and scales so a zero, mirrored, or NaN scale cannot collapse or
        /// fling input into a corner via an unchecked `CGEvent`.
        private func validatedNativePoint(x: Double, y: Double, scaleX: Double, scaleY: Double) throws -> CGPoint {
            guard x.isFinite, y.isFinite else {
                throw NSError(
                    domain: "DesktopControl", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates (x: \(x), y: \(y)): must be finite numbers"]
                )
            }
            guard x >= 0, y >= 0, x <= Self.maxCoordinateValue, y <= Self.maxCoordinateValue else {
                throw NSError(
                    domain: "DesktopControl", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Coordinates out of range (x: \(x), y: \(y)): must be within 0...\(Self.maxCoordinateValue)"]
                )
            }
            guard scaleX.isFinite, scaleY.isFinite,
                  scaleX > 0, scaleY > 0,
                  scaleX <= Self.maxScaleFactor, scaleY <= Self.maxScaleFactor
            else {
                throw NSError(
                    domain: "DesktopControl", code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid scale factors (scale_x: \(scaleX), scale_y: \(scaleY)): must be finite, positive, and at most \(Self.maxScaleFactor)"
                    ]
                )
            }
            let native = CGPoint(x: x * scaleX, y: y * scaleY)
            guard native.x.isFinite, native.y.isFinite else {
                throw NSError(
                    domain: "DesktopControl", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Translated coordinates are non-finite (x: \(x) * \(scaleX), y: \(y) * \(scaleY))"]
                )
            }
            return native
        }

        /// Switches focus to the named application.
        private func switchToApp(_ appName: String, blockedApps: [String]) throws -> String {
            try checkSwitchTarget(appName, blockedApps: blockedApps)
            let apps = NSWorkspace.shared.runningApplications
            let lowered = appName.lowercased()
            guard let app = apps.first(where: {
                $0.localizedName?.lowercased() == lowered
                    || $0.localizedName?.lowercased().contains(lowered) == true
            }) else {
                throw DesktopControlError.actionFailed(
                    index: 0, reason: "Application '\(appName)' not found among running apps"
                )
            }
            app.activate()
            return "Switched to \(app.localizedName ?? appName)"
        }

        /// Moves the mouse cursor to a position.
        private func moveMouse(to point: CGPoint) {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }
            event.post(tap: .cghidEventTap)
        }

        /// Performs a single click.
        private func performClick(at point: CGPoint, button: MouseButton, modifiers: [KeyModifier]) {
            let downType: CGEventType
            let upType: CGEventType
            let cgButton: CGMouseButton
            switch button {
            case .left:
                downType = .leftMouseDown
                upType = .leftMouseUp
                cgButton = .left
            case .right:
                downType = .rightMouseDown
                upType = .rightMouseUp
                cgButton = .right
            }
            guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: downType,
                mouseCursorPosition: point,
                mouseButton: cgButton
            ) else { return }
            let flags = cgEventFlags(for: modifiers)
            down.flags = flags
            down.post(tap: .cghidEventTap)

            guard let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: upType,
                mouseCursorPosition: point,
                mouseButton: cgButton
            ) else { return }
            mouseUp.flags = flags
            mouseUp.post(tap: .cghidEventTap)
        }

        /// Performs a double-click.
        private func performDoubleClick(at point: CGPoint, modifiers: [KeyModifier]) {
            let flags = cgEventFlags(for: modifiers)
            for clickCount in [1, 2] as [Int64] {
                guard let down = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseDown,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else { return }
                down.flags = flags
                down.setIntegerValueField(.mouseEventClickState, value: clickCount)
                down.post(tap: .cghidEventTap)

                guard let mouseUp = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseUp,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else { return }
                mouseUp.flags = flags
                mouseUp.setIntegerValueField(.mouseEventClickState, value: clickCount)
                mouseUp.post(tap: .cghidEventTap)
            }
        }

        /// Performs a drag operation.
        private func performDrag(from: CGPoint, to: CGPoint) {
            // Mouse down at start
            guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: from,
                mouseButton: .left
            ) else { return }
            down.post(tap: .cghidEventTap)

            // Drag to destination
            guard let drag = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: to,
                mouseButton: .left
            ) else { return }
            drag.post(tap: .cghidEventTap)

            // Mouse up at destination
            guard let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: to,
                mouseButton: .left
            ) else { return }
            mouseUp.post(tap: .cghidEventTap)
        }

        /// Types a string by posting keyboard events for each character.
        /// Checks the shared stop flag and task cancellation every character
        /// so a long `type_text` aborts mid-action instead of running out.
        private func typeString(_ text: String) async throws {
            for character in text {
                try Task.checkCancellation()
                if await DesktopControlMonitor.shared.shouldAbort() {
                    throw DesktopControlError.emergencyStopped
                }
                let unicodeScalar = Array(character.unicodeScalars)
                guard unicodeScalar.first != nil else { continue }
                let codeUnits = unicodeScalar.map { UniChar($0.value) }
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
                down.keyboardSetUnicodeString(
                    stringLength: codeUnits.count,
                    unicodeString: codeUnits
                )
                down.post(tap: .cghidEventTap)

                guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
                keyUp.keyboardSetUnicodeString(
                    stringLength: codeUnits.count,
                    unicodeString: codeUnits
                )
                keyUp.post(tap: .cghidEventTap)
            }
        }

        /// Presses a named key with optional modifiers.
        private func pressKey(_ key: String, modifiers: [KeyModifier]) throws {
            // Single characters use Unicode posting so the typed character
            // matches the request instead of always posting virtual key 0.
            if key.count == 1, let character = key.first {
                try postUnicodeCharacter(character, modifiers: modifiers)
                return
            }
            guard let keyCode = virtualKeyCode(for: key) else {
                let valid = "Return, Escape, Tab, Space, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp/Down, F1-F12."
                throw DesktopControlError.actionFailed(
                    index: 0,
                    reason: "Unknown key name: '\(key)'. Supported: \(valid)"
                )
            }
            let flags = cgEventFlags(for: modifiers)

            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
            down.flags = flags
            down.post(tap: .cghidEventTap)

            guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
            keyUp.flags = flags
            keyUp.post(tap: .cghidEventTap)
        }

        /// Posts a single character via Unicode events with matching buffers.
        private func postUnicodeCharacter(_ character: Character, modifiers: [KeyModifier]) throws {
            let scalars = Array(character.unicodeScalars)
            guard !scalars.isEmpty else {
                throw DesktopControlError.actionFailed(
                    index: 0, reason: "Unmappable character for key_press"
                )
            }
            let codeUnits = scalars.map { UniChar($0.value) }
            let flags = cgEventFlags(for: modifiers)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
            down.flags = flags
            down.keyboardSetUnicodeString(
                stringLength: codeUnits.count,
                unicodeString: codeUnits
            )
            down.post(tap: .cghidEventTap)

            guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
            keyUp.flags = flags
            keyUp.keyboardSetUnicodeString(
                stringLength: codeUnits.count,
                unicodeString: codeUnits
            )
            keyUp.post(tap: .cghidEventTap)
        }

        /// Performs a scroll wheel event.
        private func performScroll(deltaX: Int32, deltaY: Int32) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            ) else { return }
            event.post(tap: .cghidEventTap)
        }

        /// Converts modifier list to CGEventFlags.
        private func cgEventFlags(for modifiers: [KeyModifier]) -> CGEventFlags {
            var flags = CGEventFlags()
            for mod in modifiers {
                switch mod {
                case .cmd: flags.insert(.maskCommand)
                case .shift: flags.insert(.maskShift)
                case .alt: flags.insert(.maskAlternate)
                case .ctrl: flags.insert(.maskControl)
                }
            }
            return flags
        }

        /// Maps named keys to virtual key codes.
        private func virtualKeyCode(for key: String) -> CGKeyCode? {
            let lowered = key.lowercased()
            let mapping: [String: CGKeyCode] = [
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
                "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F
            ]
            if let code = mapping[lowered] {
                return code
            }
            return nil
        }
    }

#endif
