// Rune Weaver App Tests — Menu bar approval surface is signal-only.

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

    /// Absence of the native decision surface is pinned by call-site compile: the test target
    /// builds the app module, so a dangled reference to a removed decision entry point fails this
    /// build.
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

    @Test
    func `approval notifications alert with sound once and update severity silently without duplicate chime`() async {
        let manager = AppNotificationManager()
        var delivered: [UNNotificationRequest] = []
        manager.requestSink = { req in
            delivered.append(req)
        }

        let initial = PermissionRequest(
            toolName: "bash",
            description: "Run command",
            input: ToolInput(toolName: "bash", argumentsJSON: "{}")
        )

        // 1. Initial unenriched filing
        await manager.postApprovalAttention(initial)
        #expect(delivered.count == 1)
        #expect(delivered[0].identifier == "approval-\(initial.id.uuidString)")
        #expect(delivered[0].content.sound != nil)
        #expect(delivered[0].content.body.contains("unknown"))

        // 2. Duplicate filing with identical severity: no second notification posted
        await manager.postApprovalAttention(initial)
        #expect(delivered.count == 1)

        // 3. Enriched update arriving ~200ms later: updates content silently (zero second chime)
        let enriched = PermissionRequest(
            id: initial.id,
            toolName: "bash",
            description: "Run command",
            input: ToolInput(toolName: "bash", argumentsJSON: "{}"),
            assessment: ImpactAssessment(severity: .dangerous, outcome: "Modifies system files")
        )
        await manager.postApprovalAttention(enriched)
        #expect(delivered.count == 2)
        #expect(delivered[1].identifier == "approval-\(initial.id.uuidString)")
        #expect(delivered[1].content.sound == nil)
        #expect(delivered[1].content.body.contains("dangerous"))

        // 4. Repeated enriched update: no third notification posted
        await manager.postApprovalAttention(enriched)
        #expect(delivered.count == 2)
    }

    @Test
    func `notify uses deterministic identifier when provided`() async {
        let manager = AppNotificationManager()
        var delivered: [UNNotificationRequest] = []
        manager.requestSink = { req in
            delivered.append(req)
        }

        await manager.notify(title: "Rune Weaver: Job", body: "Ran", identifier: "test-alert")
        #expect(delivered.count == 1)
        #expect(delivered[0].identifier == "test-alert")
        #expect(delivered[0].content.title == "Rune Weaver: Job")
        #expect(delivered[0].content.body == "Ran")
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
