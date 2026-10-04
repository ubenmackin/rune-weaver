// Rune Weaver App — Permission vocabulary for the onboarding window.
//
// Defines the ordered permission kinds, live statuses, row actions, and
// System Settings panes behind the first-run Permissions window. The ordering
// of PermissionKind is the presentation order, so inserting a new capability
// means appending in the place it should appear rather than sorting elsewhere.
// This file owns the user-facing copy and the pure status/action mappings;
// live TCC queries live in PermissionProbes so tests can exercise every
// mapping without ever prompting for real consent.
//
// Scope: app-layer presentation plus pure mappings only. No TCC calls, no
// UserDefaults, no window logic — those belong to the probes and the
// onboarding store.
// Architectural role: single vocabulary shared by the probes, the store gate,
// and the Permissions window, keeping status interpretation identical in
// production reads and in tests.

import Contacts
import Foundation
import RuneWeaverCore

/// Ordered capabilities surfaced in the Permissions window.
///
/// Declaration order is the UI order: Messages History first because search
/// and send confirmation depend on it, Send Messages last because it is only
/// meaningful once history is readable.
public enum PermissionKind: String, CaseIterable, Sendable {
    case fullDiskAccess
    case contacts
    case accessibility
    case screenRecording
    case messagesAutomation
}

/// Live readability state for one capability.
///
/// Separate from the raw platform values so the window reasons about one
/// closed set: granted means usable now, denied means the owner refused,
/// notDetermined means no prompt has been answered yet, deferred means the
/// system will ask on first use, and unavailable means the capability cannot
/// be granted on this install.
public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    case deferred
    case unavailable
}

/// Row affordance derived from a live status.
///
/// The window never invents per-row behavior inline; every row maps its
/// status through PermissionActionsMapping so the affordance stays
/// consistent when a status flips after a request.
public enum PermissionAction: Sendable, Equatable {
    case none
    case enable
    case openSettings
}

/// System Settings privacy pane backing each capability.
///
/// The URL opens the exact privacy section so the owner lands one click from
/// the toggle instead of the top-level pane.
public enum PermissionPane: String, Sendable {
    case allFiles
    case contacts
    case accessibility
    case screenCapture
    case automation

    /// Deep link into System Settings for this pane.
    ///
    /// Each string names the privacy section directly; a nil result would
    /// mean the link shape changed, in which case the row falls back to
    /// opening nothing rather than a wrong section.
    public var url: URL? {
        switch self {
        case .allFiles:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .contacts:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenCapture:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .automation:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        }
    }
}

extension PermissionKind {
    /// Short row title shown in the Permissions window.
    public var title: String {
        switch self {
        case .fullDiskAccess:
            "Messages History"
        case .contacts:
            "Contacts"
        case .accessibility:
            "Desktop Control"
        case .screenRecording:
            "Screen Capture"
        case .messagesAutomation:
            "Send Messages"
        }
    }

    /// Why the capability matters, shown beneath the row title.
    ///
    /// Full Disk Access names the missing-prompt trap explicitly because the
    /// system never asks; the owner must add the app by hand, so the copy
    /// has to say so instead of implying a button will prompt.
    public var rationale: String {
        switch self {
        case .fullDiskAccess:
            "Full Disk Access lets Rune Weaver read your local Messages database for search, read, and send "
                + "confirmation. macOS has no prompt for this permission, so add Rune Weaver in System Settings."
        case .contacts:
            "Lets Rune Weaver resolve names like \"Rebecca Mackin\" to phone numbers and email addresses."
        case .accessibility:
            "Lets Rune Weaver move the mouse, click, and type during approved desktop tasks."
        case .screenRecording:
            "Lets Rune Weaver take screenshots during approved desktop tasks so it can see what it is doing."
        case .messagesAutomation:
            "Lets Rune Weaver send messages through Messages when you ask it to."
        }
    }

    /// SF Symbol backing the row icon.
    public var systemImage: String {
        switch self {
        case .fullDiskAccess:
            "externaldrive.fill"
        case .contacts:
            "person.crop.circle"
        case .accessibility:
            "cursorarrow.motionlines"
        case .screenRecording:
            "rectangle.on.rectangle"
        case .messagesAutomation:
            "paperplane.fill"
        }
    }

    /// Settings pane opened when the row needs manual approval.
    public var pane: PermissionPane {
        switch self {
        case .fullDiskAccess:
            .allFiles
        case .contacts:
            .contacts
        case .accessibility:
            .accessibility
        case .screenRecording:
            .screenCapture
        case .messagesAutomation:
            .automation
        }
    }
}

extension PermissionStatus {
    /// Short human-readable state shown in the row subtitle.
    public var label: String {
        switch self {
        case .granted:
            "Granted"
        case .denied:
            "Not granted"
        case .notDetermined:
            "Not yet requested"
        case .deferred:
            "Asks on first send"
        case .unavailable:
            "Unavailable"
        }
    }
}

/// Pure translation from platform states into PermissionStatus.
///
/// Kept free of side effects so both the live probes and the test suite share
/// one interpretation: a TCC denial always reads denied, an untouched prompt
/// always reads notDetermined, and anything unrecognized reads unavailable
/// rather than guessing granted.
public enum PermissionStatusMapping {
    /// Interprets the Contacts authorization state.
    ///
    /// Limited access still withholds arbitrary lookups the send path needs,
    /// so it reads denied rather than granted; an unknown future case reads
    /// unavailable so the window never claims access it has not verified.
    public static func contacts(_ status: CNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:
            .granted
        case .denied, .restricted, .limited:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .unavailable
        }
    }

    /// Interprets the Accessibility trust flag.
    ///
    /// Platform limitation: the silent trust query reports only a Bool with
    /// no denied-versus-unasked distinction, so false maps to notDetermined
    /// and keeps the Enable affordance (fail-open). Routing an untouched
    /// install straight to Settings would strand first-run owners who never
    /// saw a dialog, while the prompting Enable variant stays the repair
    /// path: it re-invokes the system prompt when still answerable and the
    /// owner can still reach the pane by hand when the system suppresses it.
    public static func accessibility(trusted: Bool) -> PermissionStatus {
        trusted ? .granted : .notDetermined
    }

    /// Interprets the Screen Recording preflight flag.
    ///
    /// Platform limitation: the preflight reports only a Bool with no
    /// denied-versus-unasked distinction, so false maps to notDetermined
    /// and keeps the Enable affordance (fail-open). Same bargain as
    /// Accessibility: first-run owners keep the prompting path instead of a
    /// premature Settings detour, and the prompting variant stays the repair
    /// path when the grant is still answerable.
    public static func screenRecording(hasAccess: Bool) -> PermissionStatus {
        hasAccess ? .granted : .notDetermined
    }

    /// Interprets a Full Disk Access snapshot attempt.
    ///
    /// Success proves readability; an explicit permission denial proves the
    /// grant is missing; any other failure (missing database, unreadable
    /// snapshot) is environmental, so it reads unavailable rather than denied.
    public static func fullDiskAccess(result: Result<Void, Error>) -> PermissionStatus {
        switch result {
        case .success:
            return .granted
        case let .failure(error):
            if let indexError = error as? MessagesIndexError,
               case .permissionDenied = indexError
            {
                return .denied
            }
            return .unavailable
        }
    }

    /// Interprets the Automation consent query for Messages.
    ///
    /// The target-not-running shape reads deferred because the system will
    /// ask on first send; anything outside the four documented outcomes reads
    /// unavailable so an OS change fails closed instead of claiming granted.
    public static func automation(_ status: OSStatus) -> PermissionStatus {
        switch status {
        case noErr:
            .granted
        case OSStatus(errAEEventNotPermitted):
            .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            .notDetermined
        case OSStatus(procNotFound):
            .deferred
        default:
            .unavailable
        }
    }
}

/// Pure translation from a live status into its row affordance.
///
/// Granted and deferred rows need no action (deferred resolves on first
/// send); an unanswered prompt offers Enable; an explicit denial or an
/// environmental failure points at Settings where the owner can repair it.
public enum PermissionActionsMapping {
    public static func action(for status: PermissionStatus) -> PermissionAction {
        switch status {
        case .granted:
            .none
        case .notDetermined:
            .enable
        case .denied:
            .openSettings
        case .deferred:
            .none
        case .unavailable:
            .openSettings
        }
    }
}
