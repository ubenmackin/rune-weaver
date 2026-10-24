// Rune Weaver App — Native macOS Notification Manager.

import Foundation
import RuneWeaverCore
import UserNotifications
#if canImport(AppKit)
    import AppKit
#endif

/// Category identifiers for native notifications.
enum NotificationCategories {
    static let schedulerRun = "SCHEDULER_RUN"
}

/// Action identifiers for native notifications.
enum NotificationActions {
    static let openDashboard = "OPEN_DASHBOARD_ACTION"
}

/// User-info marker that distinguishes an approval-attention notification,
/// whose tap opens the dashboard inbox, from a scheduler notification, whose
/// tap opens the dashboard.
private let approvalAttentionInboxKey = "opens_approval_inbox"

/// Coordinates system notifications on macOS.
/// MainActor serializes the dedup map plus the test sink across scheduler
/// and approval callbacks; NSObject internals stay MainActor-confined.
@MainActor
public final class AppNotificationManager: NSObject, UNUserNotificationCenterDelegate, SchedulerNotifier, @unchecked Sendable {
    /// Handler invoked when an approval-attention notification is tapped. The
    /// notification carries no decision affordance, so the tap only deep-links
    /// to the dashboard inbox where the request can be decided.
    public var onOpenInbox: (@MainActor @Sendable () -> Void)?

    /// Handler invoked to open the web dashboard in the default browser.
    public var onOpenDashboard: (@MainActor @Sendable () -> Void)?

    /// Injected request sink for hermetic unit testing without touching UNUserNotificationCenter.
    var requestSink: (@MainActor @Sendable (UNNotificationRequest) async throws -> Void)?

    /// Bounded FIFO tracking alerted approval IDs and their last posted severity.
    private var alertedApprovalSeverities: [UUID: ImpactSeverity?] = [:]
    private var alertedApprovalOrder: [UUID] = []
    private static let maxTrackedApprovals = 500

    /// Creates an instance and sets up categories.
    override public init() {
        super.init()
    }

    /// Configures the notification center delegate, registers categories, and requests authorization.
    public func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(center: center)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                print("[AppNotificationManager] Notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    /// The interactive categories registered with the notification center.
    func notificationCategories() -> Set<UNNotificationCategory> {
        let openDashboardAction = UNNotificationAction(
            identifier: NotificationActions.openDashboard,
            title: "Open Dashboard",
            options: [.foreground]
        )
        let schedulerCategory = UNNotificationCategory(
            identifier: NotificationCategories.schedulerRun,
            actions: [openDashboardAction],
            intentIdentifiers: [],
            options: []
        )
        return [schedulerCategory]
    }

    /// Registers the interactive notification categories and actions.
    private func registerCategories(center: UNUserNotificationCenter) {
        center.setNotificationCategories(notificationCategories())
    }

    /// Posts an informational notification for a pending approval request.
    public func postApprovalAttention(_ request: PermissionRequest) async {
        let isAlreadyAlerted = alertedApprovalSeverities.keys.contains(request.id)
        if isAlreadyAlerted {
            let previousSeverity = alertedApprovalSeverities[request.id] ?? nil
            if previousSeverity == request.assessment?.severity {
                // Same severity: skip posting so we never repeat notifications.
                return
            }
        }

        trackApprovalAlert(id: request.id, severity: request.assessment?.severity)

        let content = approvalAttentionContent(request, isUpdate: isAlreadyAlerted)

        let notificationRequest = UNNotificationRequest(
            identifier: NotifyID.normalize("approval-\(request.id.uuidString)"),
            content: content,
            trigger: nil
        )

        do {
            if let requestSink {
                try await requestSink(notificationRequest)
            } else {
                try await UNUserNotificationCenter.current().add(notificationRequest)
            }
        } catch {
            print("[AppNotificationManager] Failed to post approval attention notification: \(error.localizedDescription)")
        }
    }

    private func trackApprovalAlert(id: UUID, severity: ImpactSeverity?) {
        if alertedApprovalSeverities[id] == nil {
            alertedApprovalOrder.append(id)
            if alertedApprovalOrder.count > Self.maxTrackedApprovals {
                let evicted = alertedApprovalOrder.removeFirst()
                alertedApprovalSeverities.removeValue(forKey: evicted)
            }
        }
        alertedApprovalSeverities[id] = severity
    }

    /// Builds the informational payload for a pending approval request.
    /// Internal so the notification-surface test can pin the payload shape
    /// without touching the live notification center.
    func approvalAttentionContent(_ request: PermissionRequest, isUpdate: Bool = false) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Action Requires Attention"
        content.subtitle = request.toolName
        content.body = Self.attentionBody(severity: request.assessment?.severity)
        content.sound = isUpdate ? nil : .default
        // Routed, not answered: the marker carries no request content, only the
        // destination the tap opens.
        content.userInfo = [approvalAttentionInboxKey: true]
        return content
    }

    /// Body copy for an approval-attention notification.
    private static func attentionBody(severity: ImpactSeverity?) -> String {
        let label = severity?.rawValue ?? "unknown"
        return "Severity: \(label). Decide in the dashboard Inbox."
    }

    /// Posts a scheduler job completion notification (satisfies ``SchedulerNotifier``).
    public func notify(title: String, body: String) async {
        await notify(title: title, body: body, identifier: nil)
    }

    /// Posts a notification with an optional stable identifier (satisfies ``SchedulerNotifier``).
    public func notify(title: String, body: String, identifier: String? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NotificationCategories.schedulerRun

        let finalIdentifier = NotifyID.normalize(identifier)

        let notificationRequest = UNNotificationRequest(
            identifier: finalIdentifier,
            content: content,
            trigger: nil
        )

        do {
            if let requestSink {
                try await requestSink(notificationRequest)
            } else {
                try await UNUserNotificationCenter.current().add(notificationRequest)
            }
        } catch {
            print("[AppNotificationManager] Failed to post scheduler notification: \(error.localizedDescription)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    public nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let action = response.actionIdentifier
        let opensInbox = (response.notification.request.content.userInfo[approvalAttentionInboxKey] as? Bool) ?? false
        Task {
            await self.handleNotificationAction(action: action, opensInbox: opensInbox)
            completionHandler()
        }
    }

    private func handleNotificationAction(action: String, opensInbox: Bool) async {
        if opensInbox {
            // Approval notifications carry no actions, so every tap is the
            // default one: it deep-links to the dashboard inbox rather than
            // deciding the request natively.
            onOpenInbox?()
        } else if action == NotificationActions.openDashboard || action == UNNotificationDefaultActionIdentifier {
            onOpenDashboard?()
        }
    }
}
