// Rune Weaver App — Native macOS Notification Manager.
//
// Manages UNUserNotificationCenter notifications, actionable categories
// for tool approvals (Approve / Deny), and scheduler run completion alerts.

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
public final class AppNotificationManager: NSObject, UNUserNotificationCenterDelegate, SchedulerNotifier, @unchecked Sendable {
    /// Serializes handler reads/writes: `AppModel` assigns these on the
    /// main actor while `UNUserNotificationCenterDelegate` callbacks read
    /// them on the notification-center queue, so unsynchronized access
    /// would race. Handlers are copied under the lock and invoked after
    /// unlocking, never with the lock held across `await`.
    private let lock = NSLock()
    /// Lock-guarded backing for `onApprovalDecision`.
    private var _onApprovalDecision: (@Sendable (UUID, Bool) async -> Void)?
    /// Lock-guarded backing for `onOpenDashboard`.
    private var _onOpenDashboard: (@Sendable () -> Void)?

    /// Handler invoked when an approval decision is made from a notification action.
    public var onApprovalDecision: (@Sendable (UUID, Bool) async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onApprovalDecision
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onApprovalDecision = newValue
        }
    }

    /// Handler invoked to open the web dashboard in the default browser.
    public var onOpenDashboard: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onOpenDashboard
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onOpenDashboard = newValue
        }
    }

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

    public func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    public func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // Snapshot both handlers under the lock before branching so the
        // delegate queue never races a main-actor reassignment, and so the
        // lock is never held across Task creation or handler invocation.
        let decisionHandler = onApprovalDecision
        let dashboardHandler = onOpenDashboard

        if let idString = userInfo["approval_id"] as? String, let id = UUID(uuidString: idString) {
            if action == NotificationActions.approve {
                if let decisionHandler {
                    Task {
                        await decisionHandler(id, true)
                    }
                }
            } else if action == NotificationActions.deny {
                if let decisionHandler {
                    Task {
                        await decisionHandler(id, false)
                    }
                }
            } else {
                // User clicked banner directly
                dashboardHandler?()
            }
        } else if action == NotificationActions.openDashboard || action == UNNotificationDefaultActionIdentifier {
            dashboardHandler?()
        }

        completionHandler()
    }
}
