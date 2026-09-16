// Rune Weaver App — Native macOS Notification Manager.

import Foundation
import RuneWeaverCore
import UserNotifications
#if canImport(AppKit)
    import AppKit
#endif

/// Category identifiers for native notifications.
public enum NotificationCategories {
    public static let approvalRequest = "APPROVAL_REQUEST"
    public static let schedulerRun = "SCHEDULER_RUN"
}

/// Action identifiers for native notifications.
public enum NotificationActions {
    public static let approve = "APPROVE_ACTION"
    public static let deny = "DENY_ACTION"
    public static let openDashboard = "OPEN_DASHBOARD_ACTION"
}

/// Coordinates system notifications and actionable buttons on macOS.
@MainActor
public final class AppNotificationManager: NSObject, UNUserNotificationCenterDelegate, SchedulerNotifier {
    /// Handler invoked when an approval decision is made from a notification action.
    public var onApprovalDecision: (@MainActor @Sendable (UUID, Bool) async -> Void)?

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

    /// Registers the interactive notification categories and actions.
    private func registerCategories(center: UNUserNotificationCenter) {
        let approveAction = UNNotificationAction(
            identifier: NotificationActions.approve,
            title: "Approve",
            options: []
        )
        let denyAction = UNNotificationAction(
            identifier: NotificationActions.deny,
            title: "Deny",
            options: [.destructive]
        )
        let approvalCategory = UNNotificationCategory(
            identifier: NotificationCategories.approvalRequest,
            actions: [approveAction, denyAction],
            intentIdentifiers: [],
            options: []
        )

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

        center.setNotificationCategories([approvalCategory, schedulerCategory])
    }

    /// Posts a native interactive notification for a pending tool approval request.
    public func postApprovalNotification(_ request: PermissionRequest) async {
        let content = UNMutableNotificationContent()
        content.title = "Action Requires Approval"
        content.subtitle = request.toolName
        content.body = request.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Tool call '\(request.toolName)' requires your approval to proceed."
            : request.description
        content.sound = .default
        content.categoryIdentifier = NotificationCategories.approvalRequest
        content.userInfo = ["approval_id": request.id.uuidString]

        let notificationRequest = UNNotificationRequest(
            identifier: request.id.uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            print("[AppNotificationManager] Failed to post approval notification: \(error.localizedDescription)")
        }
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
        let approvalID = (response.notification.request.content.userInfo["approval_id"] as? String).flatMap(UUID.init(uuidString:))
        Task {
            await self.handleNotificationAction(action: action, approvalID: approvalID)
            completionHandler()
        }
    }

    private func handleNotificationAction(action: String, approvalID: UUID?) async {
        if let id = approvalID {
            if action == NotificationActions.approve {
                await onApprovalDecision?(id, true)
            } else if action == NotificationActions.deny {
                await onApprovalDecision?(id, false)
            } else {
                onOpenDashboard?()
            }
        } else if action == NotificationActions.openDashboard || action == UNNotificationDefaultActionIdentifier {
            onOpenDashboard?()
        }
    }
}
