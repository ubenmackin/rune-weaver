// Rune Weaver Server — Desktop settings DTOs for the settings API.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial desktop patch for `PUT /settings`. Every field stays optional so a request carrying only
/// one key leaves the stored capture knobs and blocklist untouched instead of resetting them.
public struct DesktopSettingsUpdate: Content, Equatable {
    /// Longest edge of the downscaled screenshot in pixels.
    public var maxImageDimension: Int?
    /// JPEG compression quality for downscaled screenshots (0.0–1.0).
    public var jpegQuality: Double?
    /// Application names where `desktop.action` refuses to dispatch input.
    public var blockedApps: [String]?

    public init(
        maxImageDimension: Int? = nil,
        jpegQuality: Double? = nil,
        blockedApps: [String]? = nil
    ) {
        self.maxImageDimension = maxImageDimension
        self.jpegQuality = jpegQuality
        self.blockedApps = blockedApps
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `DesktopConfig` reuse the same merge path.
    /// - Parameter config: Complete desktop policy.
    public init(_ config: DesktopConfig) {
        self.maxImageDimension = config.maxImageDimension
        self.jpegQuality = config.jpegQuality
        self.blockedApps = config.blockedApps
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full desktop snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter desktop: Complete desktop policy.
    public init(desktop: DesktopConfig) {
        self.init(desktop: DesktopSettingsUpdate(desktop))
    }
}

// MARK: - Desktop Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial desktop patch onto the stored policy, preserving every field the request
    /// omits. A nil patch is a no-op, so a dashboard edit to one knob never resets the rest of the
    /// `[desktop]` section.
    func applyDesktop(to desktop: inout DesktopConfig) {
        guard let update = self.desktop else { return }
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
