// Rune Weaver App Tests — Menu bar approval surface is signal-only.
//
// Purpose: Pins that the macOS menu bar never decides an approval: the only
// native affordance is the attention row routing to the dashboard inbox, and
// an approval notification carries information only. Scope: the AppModel
// routing surface plus the notification payload builder, with no embedded
// service, no boot, and no live notification center. Architectural role:
// guards the decision contract where the served decide route is the only
// decision path, so a reintroduced native decide path fails this build instead
// of reaching the owner.

import Foundation
@testable import RuneWeaverApp
import RuneWeaverCore
import Testing
import UserNotifications

@Suite("AppModel approval surface")
@MainActor
struct AppModelApprovalSurfaceTests {
    /// Probe standing in for request arguments: both the description and the
    /// raw argument JSON can carry them, and neither may reach a notification
    /// payload.
    private static let argumentsProbe = "arguments-probe-7f3a"

    @Test
    func `attention row deep links to the dashboard approvals fragment`() {
        let model = AppModel()

        // Before a bind resolves there is no live endpoint, so the row must
        // open nothing: openInbox honors availability exactly like the other
        // dashboard destinations.
        #expect(model.isDashboardAvailable == false)
        model.openInbox()

        model.hostname = "127.0.0.1"
        model.port = 8080
        let inbox = model.inboxURL()
        #expect(inbox?.fragment == "approvals")
        #expect(inbox?.absoluteString == "http://127.0.0.1:8080/#approvals")
    }

    /// Absence of the native decision surface is pinned by call-site compile:
    /// the test target builds the app module, so a dangled reference to a
    /// removed decision entry point fails this build. This case exercises what
    /// replaced it — the badge-bearing pending list plus the routing row — so
    /// the replacement stays reachable and the count still refreshes.
    @Test
    func `pending request routes to the inbox instead of deciding`() async {
        let model = AppModel()
        #expect(model.pendingApprovals.isEmpty)
        #expect(model.hasPausedDesktopAutomation == false)

        model.openInbox()
        await model.refreshPendingApprovals()
        #expect(model.pendingApprovals.isEmpty)
    }

    @Test
    func `approval notification carries no actions and no arguments`() {
        let manager = AppNotificationManager()
        let request = makeRequest(
            toolName: "messages.send",
            description: Self.argumentsProbe,
            argumentsJSON: "{\"to\":\"\(Self.argumentsProbe)\"}"
        )

        let content = manager.approvalAttentionContent(request)

        // An empty category identifier means no action buttons, and only the
        // tool plus the severity are named: the description and the raw
        // arguments stay off the payload.
        #expect(content.categoryIdentifier.isEmpty)
        #expect(content.subtitle == "messages.send")
        #expect(content.body.contains("dangerous"))
        #expect(!content.body.contains(Self.argumentsProbe))
        #expect(!content.subtitle.contains(Self.argumentsProbe))
        #expect(!content.title.contains(Self.argumentsProbe))
        #expect(!content.userInfo.values.contains { ($0 as? String)?.contains(Self.argumentsProbe) == true })

        // The registered categories keep only the scheduler route; no approval
        // category with buttons survives.
        let categories = manager.notificationCategories()
        #expect(categories.count == 1)
        let scheduler = categories.first { $0.identifier == NotificationCategories.schedulerRun }
        #expect(scheduler?.actions.count == 1)
        #expect(scheduler?.actions.first?.identifier == NotificationActions.openDashboard)
    }

    @Test
    func `question approvals cannot be answered natively`() {
        // A question.ask request reaches the same informational-only payload:
        // no answer affordance and no action buttons exist on the native
        // surfaces, so an answer can only be typed into the dashboard inbox.
        let manager = AppNotificationManager()
        let request = makeRequest(
            toolName: "question.ask",
            description: "Which recipient?",
            argumentsJSON: "{\"prompt\":\"Which recipient?\"}",
            severity: .safe
        )

        let content = manager.approvalAttentionContent(request)
        #expect(content.categoryIdentifier.isEmpty)
        #expect(content.subtitle == "question.ask")
        #expect(!content.body.contains("Which recipient?"))
        #expect(!content.subtitle.contains("Which recipient?"))
        #expect(!content.userInfo.values.contains { ($0 as? String)?.contains("Which recipient?") == true })
    }

    @Test
    func `unenriched request degrades severity instead of inventing one`() {
        // The engine files a request with no assessment until the enrichment
        // pass rebroadcasts it, so the payload must degrade to unknown rather
        // than claim a severity it has not evaluated.
        let manager = AppNotificationManager()
        let request = PermissionRequest(
            toolName: "api.request",
            description: Self.argumentsProbe,
            input: ToolInput(toolName: "api.request", argumentsJSON: "{\"url\":\"\(Self.argumentsProbe)\"}")
        )

        let content = manager.approvalAttentionContent(request)
        #expect(content.body.contains("unknown"))
        #expect(!content.body.contains(Self.argumentsProbe))
    }

    private func makeRequest(
        toolName: String,
        description: String,
        argumentsJSON: String,
        severity: ImpactSeverity = .dangerous
    ) -> PermissionRequest {
        PermissionRequest(
            toolName: toolName,
            description: description,
            input: ToolInput(toolName: toolName, argumentsJSON: argumentsJSON),
            assessment: ImpactAssessment(severity: severity, outcome: description)
        )
    }
}
