// Rune Weaver Server — Desktop settings DTOs for the settings API.
//
// Purpose: carries the partial desktop patch for `PUT /settings` so dashboard
// edits preserve untouched fields while the screenshot and control toggles
// plus capture knobs apply without a restart.
// Scope: REST patch bodies only; the settings request type owns merge policy
// while validation and persistence stay with the config layer.
// Architectural role: keeps desktop Codable contracts version-tolerant and
// decoupled from the broader settings surface.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial desktop patch for `PUT /settings`.
///
/// Every field stays optional so a request carrying only one key leaves the
/// stored toggles, dimensions, quality, and blocklist untouched instead of
/// resetting them. Covers the same field set as the full `DesktopConfig`
/// snapshot, so a caller holding a complete policy can build the patch
/// through `init(_:)` and reuse the merge path without hand-mapping fields.
public struct DesktopSettingsUpdate: Content, Equatable {
    /// Allow boundary for `desktop.screenshot`: false force-disables the
    /// tool on the bus while it stays registered; true lets the tool-state
    /// toggle decide.
    public var screenCaptureEnabled: Bool?
    /// Allow boundary for `desktop.action`: false force-disables the tool
    /// on the bus while it stays registered; true lets the tool-state
    /// toggle decide.
    public var controlEnabled: Bool?
    /// Longest edge of the downscaled screenshot in pixels.
    public var maxImageDimension: Int?
    /// JPEG compression quality for downscaled screenshots (0.0–1.0).
    public var jpegQuality: Double?
    /// Application names where `desktop.action` refuses to dispatch input.
    public var blockedApps: [String]?

    public init(
        screenCaptureEnabled: Bool? = nil,
        controlEnabled: Bool? = nil,
        maxImageDimension: Int? = nil,
        jpegQuality: Double? = nil,
        blockedApps: [String]? = nil
    ) {
        self.screenCaptureEnabled = screenCaptureEnabled
        self.controlEnabled = controlEnabled
        self.maxImageDimension = maxImageDimension
        self.jpegQuality = jpegQuality
        self.blockedApps = blockedApps
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `DesktopConfig` reuse the same merge path.
    /// - Parameter config: Complete desktop policy.
    public init(_ config: DesktopConfig) {
        self.screenCaptureEnabled = config.screenCaptureEnabled
        self.controlEnabled = config.controlEnabled
        self.maxImageDimension = config.maxImageDimension
        self.jpegQuality = config.jpegQuality
        self.blockedApps = config.blockedApps
    }

    private enum CodingKeys: String, CodingKey {
        case screenCaptureEnabled = "screen_capture_enabled"
        case controlEnabled = "control_enabled"
        case maxImageDimension = "max_image_dimension"
        case jpegQuality = "jpeg_quality"
        case blockedApps = "blocked_apps"
    }
}

public extension UpdateSettingsRequest {
    /// Builds a request from a full desktop snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter desktop: Complete desktop policy.
    init(desktop: DesktopConfig) {
        self.init(desktop: DesktopSettingsUpdate(desktop))
    }
}

// MARK: - Desktop Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial desktop patch onto the stored policy, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit to
    /// one knob never resets the rest of the `[desktop]` section. Values land
    /// verbatim because range checks stay single-sourced in
    /// `RuneWeaverConfig.validate`, which runs before the merged config persists.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the desktop-specific logic lives beside its DTOs.
    func applyDesktop(to desktop: inout DesktopConfig) {
        guard let update = self.desktop else { return }
        if let screenCaptureEnabled = update.screenCaptureEnabled {
            desktop.screenCaptureEnabled = screenCaptureEnabled
        }
        if let controlEnabled = update.controlEnabled {
            desktop.controlEnabled = controlEnabled
        }
        if let maxImageDimension = update.maxImageDimension {
            desktop.maxImageDimension = maxImageDimension
        }
        if let jpegQuality = update.jpegQuality {
            desktop.jpegQuality = jpegQuality
        }
        if let blockedApps = update.blockedApps {
            desktop.blockedApps = blockedApps
        }
    }
}
