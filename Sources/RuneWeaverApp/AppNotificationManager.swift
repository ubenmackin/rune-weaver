// Rune Weaver App — Native macOS Notification Manager.

import Foundation
import RuneWeaverCore
import UserNotifications
#if canImport(AppKit)
    import AppKit
#endif

/// Category identifiers for native notifications.
public enum NotificationCategories {
    public static let schedulerRun = "SCHEDULER_RUN"
}

/// Action identifiers for native notifications.
public enum NotificationActions {
    public static let openDashboard = "OPEN_DASHBOARD_ACTION"
}

/// User-info marker that distinguishes an approval-attention notification,
/// whose tap opens the dashboard inbox, from a scheduler notification, whose
/// tap opens the dashboard.
private let approvalAttentionInboxKey = "opens_approval_inbox"

/// Coordinates system notifications on macOS.
@MainActor
public final class AppNotificationManager: NSObject, UNUserNotificationCenterDelegate, SchedulerNotifier {
    /// Handler invoked when an approval-attention notification is tapped. The
    /// notification carries no decision affordance, so the tap only deep-links
    /// to the dashboard inbox where the request can be decided.
    public var onOpenInbox: (@MainActor @Sendable () -> Void)?

    /// Handler invoked to open the web dashboard in the default browser.
    public var onOpenDashboard: (@MainActor @Sendable () -> Void)?

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
    /// Internal so the notification-surface test can pin that only the
    /// scheduler category survives and that no approval category with
    /// action buttons exists.
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
    ///
    /// The payload names only the tool and its severity: the request
    /// description and its arguments stay off the notification surface, and the
    /// notification carries no category and no actions, so no decision can
    /// originate here. The tap deep-links to the dashboard inbox through the
    /// existing open path.
    public func postApprovalAttention(_ request: PermissionRequest) async {
        let content = approvalAttentionContent(request)

        let notificationRequest = UNNotificationRequest(
            identifier: request.id.uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            print("[AppNotificationManager] Failed to post approval attention notification: \(error.localizedDescription)")
        }
    }

    /// Builds the informational payload for a pending approval request.
    /// Internal so the notification-surface test can pin the payload shape
    /// without touching the live notification center.
    func approvalAttentionContent(_ request: PermissionRequest) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Action Requires Attention"
        content.subtitle = request.toolName
        content.body = Self.attentionBody(severity: request.assessment?.severity)
        content.sound = .default
        // Routed, not answered: the marker carries no request content, only the
        // destination the tap opens.
        content.userInfo = [approvalAttentionInboxKey: true]
        return content
    }

    /// Body copy for an approval-attention notification. Names only the
    /// evaluated severity and points at the one place a decision can be made;
    /// an engine-filed request that has not been enriched yet reports unknown
    /// rather than inventing a severity.
    private static func attentionBody(severity: ImpactSeverity?) -> String {
        let label = severity?.rawValue ?? "unknown"
        return "Severity: \(label). Decide in the dashboard Inbox."
    }

    /// Posts a scheduler job completion notification (satisfies ``SchedulerNotifier``).
    public func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NotificationCategories.schedulerRun

        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
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
