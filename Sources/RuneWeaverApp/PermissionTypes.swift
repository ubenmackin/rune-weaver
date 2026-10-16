// Rune Weaver App — Permission vocabulary for the onboarding window.

import Contacts
import EventKit
import Foundation
import RuneWeaverCore
import Speech

/// Ordered capabilities surfaced in the Permissions window.
public enum PermissionKind: String, CaseIterable, Sendable {
    case fullDiskAccess
    case contacts
    case calendars
    case reminders
    case speechRecognition
    case accessibility
    case screenRecording
    case messagesAutomation
}

/// Live readability state for one capability.
public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    case deferred
    case unavailable
}

/// Row affordance derived from a live status.
public enum PermissionAction: Sendable, Equatable {
    case none
    case enable
    case openSettings
}

/// System Settings privacy pane backing each capability.
public enum PermissionPane: String, Sendable {
    case allFiles
    case contacts
    case calendars
    case reminders
    case speechRecognition
    case accessibility
    case screenCapture
    case automation

    /// Deep link into System Settings for this pane.
    public var url: URL? {
        switch self {
        case .allFiles:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .contacts:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
        case .calendars:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case .reminders:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        case .speechRecognition:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
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
        case .calendars:
            "Calendars"
        case .reminders:
            "Reminders"
        case .speechRecognition:
            "Speech Recognition"
        case .accessibility:
            "Desktop Control"
        case .screenRecording:
            "Screen Capture"
        case .messagesAutomation:
            "Send Messages"
        }
    }

    /// Why the capability matters, shown beneath the row title.
    public var rationale: String {
        switch self {
        case .fullDiskAccess:
            "Full Disk Access lets Rune Weaver read your local Messages database for search, read, and send "
                + "confirmation. macOS has no prompt for this permission, so add Rune Weaver in System Settings."
        case .contacts:
            "Lets Rune Weaver resolve names like \"Rebecca Mackin\" to phone numbers and email addresses."
        case .calendars:
            "Lets Rune Weaver search your calendars and create events when you ask it to."
        case .reminders:
            "Lets Rune Weaver search your reminders and create tasks when you ask it to."
        case .speechRecognition:
            "Lets Rune Weaver transcribe speech from audio recordings, voice memos, and videos during indexing."
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
        case .calendars:
            "calendar"
        case .reminders:
            "checklist"
        case .speechRecognition:
            "waveform"
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
        case .calendars:
            .calendars
        case .reminders:
            .reminders
        case .speechRecognition:
            .speechRecognition
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
enum PermissionStatusMapping {
    /// Interprets the Contacts authorization state.
    static func contacts(_ status: CNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:
            .granted
        case .denied, .restricted, .limited:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            // Unknown future cases fail closed to denied so no layer claims access it has not verified.
            .denied
        }
    }

    /// Interprets the Speech Recognition authorization state.
    static func speechRecognition(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:
            .granted
        case .denied, .restricted:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }

    /// Interprets any EventKit authorization state.
    static func eventKit(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess:
            .granted
        case .denied, .restricted, .writeOnly:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            // Unknown future cases fail closed to denied so no layer claims access it has not verified.
            .denied
        }
    }

    /// Interprets the Calendars authorization state.
    static func calendars(_ status: EKAuthorizationStatus) -> PermissionStatus {
        eventKit(status)
    }

    /// Interprets the Reminders authorization state.
    static func reminders(_ status: EKAuthorizationStatus) -> PermissionStatus {
        eventKit(status)
    }

    /// Interprets the Accessibility trust flag.
    static func accessibility(trusted: Bool) -> PermissionStatus {
        trusted ? .granted : .notDetermined
    }

    /// Interprets the Screen Recording preflight flag.
    static func screenRecording(hasAccess: Bool) -> PermissionStatus {
        hasAccess ? .granted : .notDetermined
    }

    /// Interprets a Full Disk Access snapshot attempt.
    static func fullDiskAccess(result: Result<Void, Error>) -> PermissionStatus {
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
    static func automation(_ status: OSStatus) -> PermissionStatus {
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
enum PermissionActionsMapping {
    static func action(for status: PermissionStatus) -> PermissionAction {
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
