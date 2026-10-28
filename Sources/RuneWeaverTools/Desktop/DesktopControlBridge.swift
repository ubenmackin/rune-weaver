// Rune Weaver Tools — Desktop control bridge for macOS automation.

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
    /// The operator moved the mouse mid-batch, displacing the cursor past the displacement
    /// threshold, or an explicit takeover was latched on the shared monitor.
    case operatorTakeover
    /// The operator took over mid-batch after earlier steps already succeeded.
    /// Carries the completed step results so the tool envelope can report
    /// partial progress instead of discarding the audit trail.
    case operatorTakeoverWithPartial(results: [DesktopActionStepResult])
    /// The platform does not support desktop control.
    case unsupportedPlatform
    /// An action in the batch failed.
    case actionFailed(index: Int, reason: String)
    /// The batch was too large.
    case batchTooLarge(count: Int, max: Int)
    /// A typed or pasted URL target was blocked or unlisted by security policy.
    case blockedURL(host: String, url: String, reason: String)

    /// Whether this error signals operator takeover in either shape.
    public var isOperatorTakeover: Bool {
        switch self {
        case .operatorTakeover, .operatorTakeoverWithPartial:
            true
        default:
            false
        }
    }

    /// Completed step results preserved by a mid-batch takeover.
    public var partialResults: [DesktopActionStepResult] {
        switch self {
        case let .operatorTakeoverWithPartial(results):
            results
        default:
            []
        }
    }
}

// MARK: - Shared emergency state

/// Shared abort source for in-flight desktop automation.
public actor DesktopControlMonitor {
    /// Process-wide shared instance bridging the menu bar and the tool.
    public static let shared = DesktopControlMonitor()

    /// Batches currently executing.
    private var activeCount = 0
    /// Latched stop request, cleared when the last batch settles.
    private var emergencyStop = false
    /// Latched operator takeover signal (mouse displacement or explicit stop).
    private var operatorTakeover = false

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

    /// Whether an operator takeover pause has been requested.
    public var isOperatorTakeoverRequested: Bool {
        operatorTakeover
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
            operatorTakeover = false
        }
    }

    /// Latches an emergency stop consumed by the running batch.
    public func requestEmergencyStop() {
        emergencyStop = true
    }

    /// Clears a latched stop without ending a batch.
    public func clearEmergencyStop() {
        emergencyStop = false
        operatorTakeover = false
    }

    /// Latches an operator takeover pause.
    public func requestOperatorTakeover() {
        operatorTakeover = true
    }

    /// Clears an operator takeover pause.
    public func clearOperatorTakeover() {
        operatorTakeover = false
    }

    /// Whether the running batch should abort at the next checkpoint.
    public func shouldAbort() -> Bool {
        emergencyStop
    }
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
    /// Maximum absolute scroll delta accepted per axis in a scroll action.
    public static let maxScrollDelta = 100_000
    /// Maximum allowed scale factor from screenshot to native coordinates.
    static let maxScaleFactor: Double = 100.0
    /// Maximum allowed coordinate value in screenshot pixel space.
    static let maxCoordinateValue: Double = 20000.0
    /// Corner margin in points for the fail-safe check.
    static let failSafeCornerMargin: CGFloat = 5.0
    /// Displacement threshold in points for detecting manual operator mouse movement.
    public static let operatorDisplacementThreshold: CGFloat = 15.0

    /// Silent Accessibility gate injected for tests; live turns query TCC.
    private let accessibilityAccess: @Sendable () async -> Bool
    /// Outbound egress supervisor screening URLs typed into apps against policy.toml.
    public let egressSupervisor: OutboundEgressSupervisor?
    /// Injected operator-takeover signal for tests and host HID bridges.
    private let operatorTakeoverDetector: (@Sendable () async -> Bool)?

    /// Creates the live bridge. The injected gate exists so bridge-level tests can exercise the
    /// fail-closed denial without touching real TCC trust; live turns keep the silent non-prompting
    /// query as the default.
    public init(
        accessibilityAccess: @escaping @Sendable () async -> Bool = {
            await MainActor.run { DesktopPermissionCheck.isAccessibilityTrusted() }
        },
        operatorTakeoverDetector: (@Sendable () async -> Bool)? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) {
        self.accessibilityAccess = accessibilityAccess
        self.operatorTakeoverDetector = operatorTakeoverDetector
        self.egressSupervisor = egressSupervisor
    }

    /// Extracts explicit HTTP/HTTPS URLs present in text.
    public static func extractURLs(from text: String) -> [String] {
        ApprovalQueue.extractLinkURLs(from: text)
    }

    /// Refuses scroll actions whose per-axis delta exceeds the posting bound so
    /// oversized values fail in preflight instead of trapping in the Int32 cast.
    nonisolated static func validateScrollDeltas(_ actions: [DesktopAction]) throws {
        for (index, action) in actions.enumerated() {
            guard case let .scroll(deltaX, deltaY) = action else { continue }
            // Both directions are compared directly; abs(Int.min) would trap.
            let bound = Self.maxScrollDelta
            if deltaX > bound || deltaX < -bound || deltaY > bound || deltaY < -bound {
                throw DesktopControlError.actionFailed(
                    index: index,
                    reason: "Scroll delta (dx: \(deltaX), dy: \(deltaY)):"
                        + " absolute value must be at most \(Self.maxScrollDelta)"
                )
            }
        }
    }

    public func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String]
    ) async throws -> [DesktopActionStepResult] {
        try await executeBatch(actions: actions, scaleX: scaleX, scaleY: scaleY, blockedApps: blockedApps, sessionID: nil)
    }

    /// Checks cooperative emergency stop and operator takeover signals.
    private func checkEmergencyStopOrTakeover() async throws {
        if await DesktopControlMonitor.shared.shouldAbort() {
            throw DesktopControlError.emergencyStopped
        }
        if await DesktopControlMonitor.shared.isOperatorTakeoverRequested {
            throw DesktopControlError.operatorTakeover
        }
        if let detector = operatorTakeoverDetector, await detector() {
            await DesktopControlMonitor.shared.requestOperatorTakeover()
            throw DesktopControlError.operatorTakeover
        }
    }

    /// Validates batch parameters and preflight safety checks before dispatching.
    private func validateBatchPreflight(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        sessionID: UUID?,
        declaredHosts: [String] = []
    ) async throws {
        try Task.checkCancellation()
        try await checkEmergencyStopOrTakeover()
        guard await accessibilityAccess() else {
            throw DesktopControlError.accessibilityPermissionDenied
        }
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
            let reason = "Invalid scale factors (scale_x: \(scaleX), scale_y: \(scaleY)): "
                + "must be finite, positive, and at most \(Self.maxScaleFactor)"
            throw DesktopControlError.actionFailed(index: 0, reason: reason)
        }
        try Self.validateScrollDeltas(actions)
        try await screenBatchURLs(actions: actions, sessionID: sessionID, declaredHosts: declaredHosts)
    }

    #if canImport(CoreGraphics) && canImport(AppKit)
        /// Validates safety conditions before a single action executes.
        private func checkActionSafety(
            action: DesktopAction,
            lastSyntheticPoint: CGPoint?,
            blockedApps: [String]
        ) async throws {
            try await checkEmergencyStopOrTakeover()
            try Task.checkCancellation()

            if let last = lastSyntheticPoint, isDisplaced(from: last) {
                await DesktopControlMonitor.shared.requestOperatorTakeover()
                throw DesktopControlError.operatorTakeover
            }

            if isMouseInCorner() {
                throw DesktopControlError.failSafeTriggered
            }

            if needsInputCheck(action) {
                try checkBlockedApp(blockedApps: blockedApps)
            }

            if case let .switchApp(appName) = action {
                try checkSwitchTarget(appName, blockedApps: blockedApps)
            }
        }
    #endif

    /// Executes a batch screened against one session's egress grants.
    public func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String],
        sessionID: UUID?
    ) async throws -> [DesktopActionStepResult] {
        try await executeBatch(
            actions: actions,
            scaleX: scaleX,
            scaleY: scaleY,
            blockedApps: blockedApps,
            sessionID: sessionID,
            declaredHosts: []
        )
    }

    /// Executes a batch screened against declared hosts plus session grants.
    public func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String],
        sessionID: UUID?,
        declaredHosts: [String]
    ) async throws -> [DesktopActionStepResult] {
        let sanitizedDeclared = SeatbeltProfileBuilder.sanitizedEgressHosts(declaredHosts)
        try await validateBatchPreflight(
            actions: actions,
            scaleX: scaleX,
            scaleY: scaleY,
            sessionID: sessionID,
            declaredHosts: sanitizedDeclared
        )

        #if canImport(CoreGraphics) && canImport(AppKit)
            var results: [DesktopActionStepResult] = []
            var lastSyntheticPoint: CGPoint?
            for (index, action) in actions.enumerated() {
                // A takeover raised by the pre-step safety check discards
                // nothing silently: the steps that already succeeded travel on
                // the error so the envelope keeps its audit trail.
                do {
                    try await checkActionSafety(
                        action: action,
                        lastSyntheticPoint: lastSyntheticPoint,
                        blockedApps: blockedApps
                    )
                } catch let takeover as DesktopControlError where takeover.isOperatorTakeover {
                    throw DesktopControlError.operatorTakeoverWithPartial(results: results)
                }

                do {
                    let (message, dispatchedPoint) = try await executeOne(
                        action: action, scaleX: scaleX, scaleY: scaleY,
                        blockedApps: blockedApps
                    )
                    if let dispatchedPoint {
                        lastSyntheticPoint = dispatchedPoint
                    }
                    results.append(DesktopActionStepResult(
                        index: index, action: action, success: true, message: message
                    ))
                } catch is CancellationError {
                    throw DesktopControlError.emergencyStopped
                } catch let controlError as DesktopControlError {
                    switch controlError {
                    case .emergencyStopped, .failSafeTriggered, .blockedApp:
                        throw controlError
                    case .operatorTakeover, .operatorTakeoverWithPartial:
                        // Mid-batch takeover preserves whatever succeeded
                        // before the abort instead of reporting zero steps.
                        throw DesktopControlError.operatorTakeoverWithPartial(results: results)
                    case let .actionFailed(_, reason):
                        results.append(DesktopActionStepResult(
                            index: index, action: action, success: false, message: reason
                        ))
                        throw DesktopControlError.actionFailed(index: index, reason: reason)
                    default:
                        let desc = controlError.localizedDescription
                        results.append(DesktopActionStepResult(
                            index: index, action: action, success: false, message: desc
                        ))
                        throw DesktopControlError.actionFailed(index: index, reason: desc)
                    }
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

    /// Screens all typed URLs in a batch against the egress supervisor before execution.
    private func screenBatchURLs(actions: [DesktopAction], sessionID: UUID?, declaredHosts: [String] = []) async throws {
        let batchHosts = collectedBatchHosts(from: actions)
        // Fail-closed on missing supervision: typed hosts without a
        // supervisor would run unscreened. Host-free batches need no
        // screening and still proceed.
        guard let supervisor = egressSupervisor else {
            guard !batchHosts.isEmpty else { return }
            throw nilSupervisorError(hosts: batchHosts)
        }
        let undeclared = supervisor.checkHosts(batchHosts, against: declaredHosts)
        if !undeclared.isEmpty {
            throw undeclaredHostsError(undeclared: Set(undeclared), declaredHosts: declaredHosts)
        }
        var validatedHosts = Set<String>()
        for action in actions {
            guard case let .typeText(text) = action else { continue }
            let candidates = batchCandidates(for: text)
            try await validateBatchCandidates(
                candidates,
                sessionID: sessionID,
                validatedHosts: &validatedHosts
            )
        }
    }

    /// Collects every typed host once for the declared check.
    private func collectedBatchHosts(from actions: [DesktopAction]) -> [String] {
        var batchHosts: [String] = []
        var batchSeen = Set<String>()
        for action in actions {
            guard case let .typeText(text) = action else { continue }
            collectBatchHosts(from: text, seen: &batchSeen, hosts: &batchHosts)
        }
        return batchHosts
    }

    /// Collects link plus schemeless hosts from one typed text.
    private func collectBatchHosts(from text: String, seen: inout Set<String>, hosts: inout [String]) {
        for rawURL in Self.extractURLs(from: text) {
            guard let host = URL(string: rawURL)?.host, !host.isEmpty else { continue }
            let canonical = SensitiveAddressNormalization.normalizedHost(host)
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            hosts.append(host)
        }
        for bareHost in ApprovalQueue.extractAllSchemelessHosts(in: text) {
            guard let assumedHost = URL(string: "https://" + bareHost)?.host,
                  !assumedHost.isEmpty
            else { continue }
            let canonical = SensitiveAddressNormalization.normalizedHost(assumedHost)
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            hosts.append(assumedHost)
        }
    }

    /// Builds the undeclared typed-host refusal for one batch.
    ///
    /// - Returns: Blocked-URL error naming the first undeclared host.
    private func undeclaredHostsError(
        undeclared: Set<String>,
        declaredHosts: [String]
    ) -> DesktopControlError {
        let listed = undeclared.sorted().joined(separator: ", ")
        let declaredClause = declaredHosts.isEmpty
            ? "no declared hosts"
            : "declared: \(declaredHosts.sorted().joined(separator: ", "))"
        RuneWeaverLog.tools.warning(
            "desktop.action denied undeclared typed host(s) \(listed) (\(declaredClause))"
        )
        let first = undeclared.sorted().first ?? ""
        return DesktopControlError.blockedURL(
            host: first,
            url: first,
            reason: "Typed host '\(first)' not in declared hosts (\(declaredClause))"
        )
    }

    /// Builds the fail-closed refusal when egress supervision is missing.
    private func nilSupervisorError(hosts: [String], display: String? = nil) -> DesktopControlError {
        let listed = hosts.sorted().joined(separator: ", ")
        RuneWeaverLog.tools.warning(
            "desktop.action denied typed host(s) \(listed) without egress supervision"
        )
        let first = hosts.sorted().first ?? ""
        let shown = display ?? first
        return DesktopControlError.blockedURL(
            host: first,
            url: shown,
            reason: "Egress supervision unavailable:"
                + " denying typed host '\(first)' fail-closed."
        )
    }

    /// Collects link plus schemeless candidates for one typed text.
    private func batchCandidates(for text: String) -> [(display: String, url: URL)] {
        var candidates: [(display: String, url: URL)] = []
        for rawURL in Self.extractURLs(from: text) {
            guard let parsed = URL(string: rawURL) else { continue }
            candidates.append((display: rawURL, url: parsed))
        }
        for bareHost in ApprovalQueue.extractAllSchemelessHosts(in: text) {
            guard let assumed = URL(string: "https://" + bareHost),
                  let assumedHost = assumed.host, !assumedHost.isEmpty
            else { continue }
            let canonicalAssumed = SensitiveAddressNormalization.normalizedHost(assumedHost)
            guard !candidates.contains(where: {
                $0.url.host.map { SensitiveAddressNormalization.normalizedHost($0) } == canonicalAssumed
            })
            else { continue }
            candidates.append((display: bareHost, url: assumed))
        }
        return candidates
    }

    /// Screens one candidate list against the egress policy. A missing supervisor denies
    /// fail-closed: host-bearing candidates must not run unscreened, while host-free candidates need
    /// no screening.
    private func validateBatchCandidates(
        _ candidates: [(display: String, url: URL)],
        sessionID: UUID?,
        validatedHosts: inout Set<String>
    ) async throws {
        guard let supervisor = egressSupervisor else {
            guard let first = candidates.first(where: { !($0.url.host ?? "").isEmpty }) else { return }
            let hosts = candidates.compactMap(\.url.host).filter { !$0.isEmpty }
            throw nilSupervisorError(hosts: hosts, display: first.display)
        }
        for (display, parsed) in candidates {
            guard let host = parsed.host, !host.isEmpty
            else { continue }
            let canonical = SensitiveAddressNormalization.normalizedHost(host)
            guard !validatedHosts.contains(canonical) else { continue }
            validatedHosts.insert(canonical)
            let verdict = await supervisor.validate(url: parsed, sessionID: sessionID)
            switch verdict {
            case .allowed:
                break
            case let .denied(reason):
                throw DesktopControlError.blockedURL(host: parsed.host ?? display, url: display, reason: reason)
            case let .unlistedDomain(host, reason):
                throw DesktopControlError.blockedURL(host: host, url: display, reason: reason)
            }
        }
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
            guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
            let frontName = frontApp.localizedName ?? ""
            let frontBundleID = frontApp.bundleIdentifier ?? ""
            let loweredFront = frontName.lowercased()
            let loweredBundle = frontBundleID.lowercased()
            for blocked in blockedApps {
                let loweredBlocked = blocked.lowercased()
                if (!loweredFront.isEmpty && loweredFront == loweredBlocked)
                    || (!loweredBundle.isEmpty && loweredBundle == loweredBlocked)
                {
                    throw DesktopControlError.blockedApp(appName: !frontName.isEmpty ? frontName : frontBundleID)
                }
            }
        }

        /// Rejects a switch_app target that matches the blocked-app list.
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

        /// Checks if an actual cursor location has moved beyond the displacement threshold from the expected position.
        public static func isDisplaced(actual: CGPoint, from expected: CGPoint) -> Bool {
            let deltaX = actual.x - expected.x
            let deltaY = actual.y - expected.y
            return hypot(deltaX, deltaY) > operatorDisplacementThreshold
        }

        /// Checks if the mouse cursor has moved beyond the displacement threshold from the expected position.
        func isDisplaced(from expected: CGPoint) -> Bool {
            guard let current = CGEvent(source: nil)?.location else { return false }
            return Self.isDisplaced(actual: current, from: expected)
        }

        /// Executes a single action, returning a human-readable result message and optional cursor position.
        private func executeOne(
            action: DesktopAction,
            scaleX: Double,
            scaleY: Double,
            blockedApps: [String]
        ) async throws -> (message: String, dispatchedPoint: CGPoint?) {
            switch action {
            case let .switchApp(appName):
                let msg = try switchToApp(appName, blockedApps: blockedApps)
                return (msg, nil)
            case let .mouseMove(x, y):
                let native = try validatedNativePoint(x: x, y: y, scaleX: scaleX, scaleY: scaleY)
                moveMouse(to: native)
                return ("Moved cursor to (\(Int(native.x)), \(Int(native.y)))", native)
            case let .click(x, y, button, modifiers):
                let native = try validatedNativePoint(x: x, y: y, scaleX: scaleX, scaleY: scaleY)
                performClick(at: native, button: button, modifiers: modifiers)
                return ("Clicked \(button.rawValue) at (\(Int(native.x)), \(Int(native.y)))", native)
            case let .doubleClick(x, y, modifiers):
                let native = try validatedNativePoint(x: x, y: y, scaleX: scaleX, scaleY: scaleY)
                performDoubleClick(at: native, modifiers: modifiers)
                return ("Double-clicked at (\(Int(native.x)), \(Int(native.y)))", native)
            case let .drag(fromX, fromY, toX, toY):
                let from = try validatedNativePoint(x: fromX, y: fromY, scaleX: scaleX, scaleY: scaleY)
                let to = try validatedNativePoint(x: toX, y: toY, scaleX: scaleX, scaleY: scaleY)
                performDrag(from: from, to: to)
                return ("Dragged from (\(Int(from.x)), \(Int(from.y))) to (\(Int(to.x)), \(Int(to.y)))", to)
            case let .typeText(text):
                guard text.count <= Self.maxTypeTextLength else {
                    throw NSError(
                        domain: "DesktopControl", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "type_text exceeds maximum length of \(Self.maxTypeTextLength) characters (got \(text.count))"]
                    )
                }
                try await typeString(text)
                let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
                return ("Typed \(text.count) characters: \"\(preview)\"", nil)
            case let .keyPress(key, modifiers):
                try pressKey(key, modifiers: modifiers)
                let modStr = modifiers.isEmpty ? "" : " with \(modifiers.map(\.rawValue).joined(separator: "+"))"
                return ("Pressed \(key)\(modStr)", nil)
            case let .scroll(deltaX, deltaY):
                // Preflight bounds deltas far below Int32.range; clamping is
                // defense-in-depth for callers that bypass preflight.
                performScroll(deltaX: Int32(clamping: deltaX), deltaY: Int32(clamping: deltaY))
                return ("Scrolled (dx: \(deltaX), dy: \(deltaY))", nil)
            case let .delay(delayMs):
                let clamped = min(max(0, delayMs), Self.maxDelayMs)
                // Sleep honors Task cancellation; the abort flag covers the
                // menu-bar stop when the turn itself was not cancelled.
                try await Task.sleep(for: .milliseconds(clamped))
                try Task.checkCancellation()
                if await DesktopControlMonitor.shared.shouldAbort() {
                    throw DesktopControlError.emergencyStopped
                }
                if await DesktopControlMonitor.shared.isOperatorTakeoverRequested {
                    throw DesktopControlError.operatorTakeover
                }
                return ("Waited \(clamped) ms", nil)
            }
        }

        /// Converts downscaled image coordinates to native display points.
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
                    || $0.bundleIdentifier?.lowercased() == lowered
                    || $0.bundleIdentifier?.lowercased().contains(lowered) == true
            }) else {
                throw DesktopControlError.actionFailed(
                    index: 0, reason: "Application '\(appName)' not found among running apps"
                )
            }
            let resolvedName = (app.localizedName ?? "").lowercased()
            let resolvedBundle = (app.bundleIdentifier ?? "").lowercased()
            for blocked in blockedApps {
                let loweredBlocked = blocked.lowercased()
                if (!resolvedName.isEmpty && (resolvedName == loweredBlocked || resolvedName.contains(loweredBlocked)))
                    || (!resolvedBundle.isEmpty && (resolvedBundle == loweredBlocked || resolvedBundle.contains(loweredBlocked)))
                {
                    throw DesktopControlError.blockedApp(appName: app.localizedName ?? appName)
                }
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

        /// UTF-16 code units for one character, the encoding CGEvent's Unicode
        /// string API expects. Surrogate pairs keep non-BMP scalars intact where
        /// a raw 32-bit scalar value truncated to 16 bits would trap at post time.
        static func unicodeCodeUnits(for character: Character) -> [UniChar] {
            Array(String(character).utf16)
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
                let codeUnits = Self.unicodeCodeUnits(for: character)
                guard !codeUnits.isEmpty, let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
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

        /// Key names accepted by `pressKey`, surfaced when a name misses the table.
        private static let supportedKeyHint =
            "Return/Enter, Escape/Esc, Tab, Space, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp/Down, F1-F12, a-z, 0-9."

        /// Hardware codes shared by named keys and shortcut characters.
        private static let keyCodeTable: [String: CGKeyCode] = [
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

        /// Reports whether a key name resolves to a hardware code.
        static func isShortcutMappable(_ key: String) -> Bool {
            keyCodeTable[key.lowercased()] != nil
        }

        /// Presses a key with optional modifiers, routing through hardware codes when needed.
        /// Unicode posting carries the character itself, so the OS never resolves it as a shortcut
        /// target when command is held.
        private func pressKey(_ key: String, modifiers: [KeyModifier]) throws {
            // Bare characters stay on the Unicode path so typing remains
            // layout-exact; modified characters need hardware codes so the
            // system sees the intended shortcut chord.
            if key.count == 1, let character = key.first, modifiers.isEmpty {
                try postUnicodeCharacter(character)
                return
            }
            guard let keyCode = virtualKeyCode(for: key) else {
                throw DesktopControlError.actionFailed(
                    index: 0,
                    reason: "Unknown key name: '\(key)'. Supported: \(Self.supportedKeyHint)"
                )
            }
            try postVirtualKey(keyCode, modifiers: modifiers)
        }

        /// Posts a hardware key chord so the system sees a real shortcut press. Both halves must
        /// dispatch for the turn to report success; a half-posted chord throws instead of
        /// masquerading as a completed shortcut.
        private func postVirtualKey(_ keyCode: CGKeyCode, modifiers: [KeyModifier]) throws {
            let flags = cgEventFlags(for: modifiers)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
                throw DesktopControlError.actionFailed(
                    index: 0, reason: "Failed to post key-down event"
                )
            }
            down.flags = flags
            down.post(tap: .cghidEventTap)

            guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                throw DesktopControlError.actionFailed(
                    index: 0, reason: "Failed to post key-up event"
                )
            }
            keyUp.flags = flags
            keyUp.post(tap: .cghidEventTap)
        }

        /// Posts a single bare character via Unicode events. The bare path never carries modifiers,
        /// so flags stay empty; a half-posted pair throws instead of reporting a completed press.
        private func postUnicodeCharacter(_ character: Character) throws {
            let codeUnits = Self.unicodeCodeUnits(for: character)
            guard !codeUnits.isEmpty else {
                throw DesktopControlError.actionFailed(
                    index: 0, reason: "Unmappable character for key_press"
                )
            }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                throw DesktopControlError.actionFailed(
                    index: 0, reason: "Failed to post key-down event"
                )
            }
            down.keyboardSetUnicodeString(
                stringLength: codeUnits.count,
                unicodeString: codeUnits
            )
            down.post(tap: .cghidEventTap)

            guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw DesktopControlError.actionFailed(
                    index: 0, reason: "Failed to post key-up event"
                )
            }
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

        /// Maps names and shortcut characters to hardware key codes.
        private func virtualKeyCode(for key: String) -> CGKeyCode? {
            Self.keyCodeTable[key.lowercased()]
        }
    }

#endif
