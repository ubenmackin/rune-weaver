// Rune Weaver Server — Wire API casing contract test.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

@Suite("Wire API Casing Contract")
struct WireCasingContractTests {
    private let dynamicUserKeyedFields: Set<String> = [
        "providers",
        "credentials",
        "stagedStates",
        "liveStates",
        "permissionOverrides",
        "status"
    ]

    private func assertNoSnakeCaseKeys(in value: Any, path: String = "$") {
        if let dict = value as? [String: Any] {
            for (key, val) in dict {
                let currentPath = "\(path).\(key)"
                #expect(!key.contains("_"), "Found snake_case wire key: '\(key)' at '\(currentPath)'")
                if dynamicUserKeyedFields.contains(key), let innerDict = val as? [String: Any] {
                    // For user-keyed maps, the keys are dynamic user values (e.g. provider names, tool names, env var keys).
                    // We skip checking the user keys themselves, but recursively validate the values.
                    for (userKey, userVal) in innerDict {
                        assertNoSnakeCaseKeys(in: userVal, path: "\(currentPath)[\(userKey)]")
                    }
                } else {
                    assertNoSnakeCaseKeys(in: val, path: currentPath)
                }
            }
        } else if let array = value as? [Any] {
            for (idx, item) in array.enumerated() {
                assertNoSnakeCaseKeys(in: item, path: "\(path)[\(idx)]")
            }
        }
    }

    private func verifyCasing(_ object: some Encodable, label: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(object)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        assertNoSnakeCaseKeys(in: jsonObject, path: label)
    }

    @Test
    func `SettingsResponse encodes with camelCase keys only`() throws {
        var config = RuneWeaverConfig.default
        config.containers.memoryMB = 1024
        config.bash.timeoutSeconds = 60
        config.workspace.quotaMB = 2048
        config.goals.enabled = true
        config.ideas.enabled = true
        config.persona.assistantName = "Friday"
        config.persona.tone = .formal
        config.persona.style = "Concise"
        config.persona.userName = "Kupan"
        config.persona.avatar = .cyan
        config.files.writePathRules = [FilesWritePathRule(path: "/tmp", posture: .live)]
        config.email.accounts = [EmailAccount(name: "work", host: "mail.example.com", port: 993, username: "user")]

        let response = SettingsResponse(config: config, configPath: "/tmp/config.toml", requiresRestart: false)
        try verifyCasing(response, label: "SettingsResponse")
    }

    @Test
    func `UpdateSettingsRequest encodes with camelCase keys only`() throws {
        var config = RuneWeaverConfig.default
        config.persona.tone = .formal
        config.persona.avatar = .cyan

        let update = UpdateSettingsRequest(
            engineName: "RuneWeaver",
            logLevel: "debug",
            compactionThresholdPercent: 75,
            maxToolIterations: 30,
            defaultProvider: "openai",
            fallbackProvider: "anthropic",
            containers: ContainersSettingsUpdate(config.containers),
            filesDenyPatterns: ["*.key"],
            filesAllowRoots: ["/workspace"],
            filesRequireApprovalOnDeny: true,
            filesWriteMode: "staged",
            filesWritePathRules: [FilesWritePathRule(path: "/tmp", posture: .live)],
            browserSearxngURL: "http://localhost:8080",
            browserSearchTimeoutSeconds: 10,
            browserMaxResults: 5,
            browserTimeoutSeconds: 15,
            browserFetchTimeoutSeconds: 10,
            searchSearxngURL: "http://localhost:8080",
            searchTimeoutSeconds: 10,
            searchMaxResults: 5,
            media: MediaSettingsUpdate(config.media),
            index: IndexSettingsUpdate(config.index),
            desktop: DesktopSettingsUpdate(config.desktop),
            bash: BashSettingsUpdate(bash: config.bash),
            workspace: WorkspaceUpdate(config.workspace),
            goals: GoalsUpdate(config.goals),
            proactive: ProactiveUpdate(config.proactive),
            ideas: IdeasUpdate(config.ideas),
            fanout: FanOutSettingsUpdate(config.fanOut),
            persona: PersonaUpdate(config.persona),
            serverHostname: "127.0.0.1",
            serverPort: 8082,
            serverAllowedHosts: ["localhost"]
        )
        try verifyCasing(update, label: "UpdateSettingsRequest")
    }

    @Test
    func `SecurityPolicyDTO and PolicyResponse encode with camelCase keys only`() throws {
        let network = NetworkEgressPolicyDTO(
            mode: "allowlist_only",
            allowedDomains: ["api.example.com"],
            blockedDomains: ["bad.example.com"],
            localExemptions: ["127.0.0.1"]
        )
        let binding = CredentialBindingDTO(
            allowedHosts: ["api.example.com"],
            allowedMethods: ["GET", "POST"],
            allowedPathPrefixes: ["/v1"]
        )
        let policy = SecurityPolicyDTO(
            version: 1,
            network: network,
            credentials: ["API_KEY": binding]
        )
        try verifyCasing(policy, label: "SecurityPolicyDTO")

        let report = PolicyLocalAccessReport(
            granted: ["127.0.0.1"],
            removed: ["192.168.1.1"],
            neverDialable: ["example.local"]
        )
        try verifyCasing(report, label: "PolicyLocalAccessReport")

        let response = PolicyResponse(
            policy: policy,
            path: "/path/to/policy.toml",
            loadedFromDisk: true,
            violations: ["none"],
            localAccess: report
        )
        try verifyCasing(response, label: "PolicyResponse")

        let updateRequest = UpdatePolicyRequest(policy: policy)
        try verifyCasing(updateRequest, label: "UpdatePolicyRequest")
    }

    @Test
    func `PermissionRequest and approval types encode with camelCase keys only`() throws {
        let req = PermissionRequest(
            toolName: "bash.exec",
            description: "Execute bash command",
            input: ToolInput(toolName: "bash.exec", argumentsJSON: "{\"cmd\":\"curl api.example.com\"}"),
            sessionID: UUID(),
            egressHost: "api.example.com",
            sandboxSummary: "seatbelt sandbox"
        )
        try verifyCasing(req, label: "PermissionRequest")

        let approvals = ApprovalsResponse(approvals: [req])
        try verifyCasing(approvals, label: "ApprovalsResponse")

        let decision = ApprovalDecisionResponse(id: req.id, approved: true, duration: .thisTime)
        try verifyCasing(decision, label: "ApprovalDecisionResponse")

        let grant = EphemeralGrantDTO(toolName: "bash.exec", scope: AccessScopeDTO(.toolWide), duration: .forSession)
        let trustResp = SessionTrustResponse(
            sessionID: UUID(),
            grants: [grant],
            egressSessionDomains: ["example.com"],
            egressOneShotDomains: []
        )
        try verifyCasing(trustResp, label: "SessionTrustResponse")

        if let rule = AccessRule(toolName: "bash.exec", scope: .toolWide, action: .allow) {
            let ruleResp = AccessRuleResponse(rule)
            try verifyCasing(ruleResp, label: "AccessRuleResponse")
            let rulesResp = AccessRulesResponse(rules: [ruleResp])
            try verifyCasing(rulesResp, label: "AccessRulesResponse")
        }
    }

    @Test
    func `Goal and Idea DTOs encode with camelCase keys only`() throws {
        let goal = WSGoalSnapshot(
            id: UUID(),
            title: "Build Feature",
            statement: "Implement camelCase standardization",
            status: "active",
            progress: WSGoalProgress(done: 3, total: 5),
            stepIntervalMinutes: 30,
            nextDueAt: Date().addingTimeInterval(1800),
            originSessionID: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            isPlanning: false
        )
        try verifyCasing(goal, label: "WSGoalSnapshot")

        let step = GoalStepDTO(
            id: UUID(),
            goalID: goal.id,
            ordinal: 1,
            title: "Write contract tests",
            status: "done",
            notes: "Contract tests guard casing",
            lastRunID: UUID()
        )
        try verifyCasing(step, label: "GoalStepDTO")

        let idea = IdeaDTO(
            id: UUID(),
            kind: "plan_adjustment",
            title: "Add Casing Contract",
            body: "Ensure wire API emits camelCase only",
            goalID: goal.id,
            status: "proposed"
        )
        try verifyCasing(idea, label: "IdeaDTO")
    }

    @Test
    func `WSWire frames encode with camelCase keys only`() throws {
        let action = ToolAction(
            toolName: "bash.exec",
            callID: "call-1",
            argumentsJSON: "{}",
            result: nil,
            roundIndex: 0
        )
        let done = WSStreamDone(
            text: "Task completed",
            sessionID: UUID(),
            toolActions: [action],
            totalTokens: 150,
            modelName: "gpt-4o",
            contextLength: 128_000,
            roundIndex: 1
        )
        try verifyCasing(done, label: "WSStreamDone")

        let chat = WSChatMessage(text: "Hello", sessionID: UUID(), source: "web", steer: false)
        try verifyCasing(chat, label: "WSChatMessage")

        let decision = WSDecisionMessage(id: UUID(), approved: true, duration: .thisTime, widen: false)
        try verifyCasing(decision, label: "WSDecisionMessage")
    }

    @Test
    func `Workspace DTOs encode with camelCase keys only`() throws {
        let usage = WorkspaceUsageResponse(
            bytes: 1024,
            files: 5,
            truncated: false,
            quotaMB: 2048,
            quotaFiles: 1000
        )
        try verifyCasing(usage, label: "WorkspaceUsageResponse")

        let prune = WorkspacePruneResponse(removed: 3)
        try verifyCasing(prune, label: "WorkspacePruneResponse")
    }

    @Test
    func `Web Push DTOs encode with camelCase keys only`() throws {
        let pubKey = VapidPublicKeyResponse(publicKey: "BP_test_key_abc")
        try verifyCasing(pubKey, label: "VapidPublicKeyResponse")

        let subPayload = PushSubscriptionPayload(
            endpoint: "https://web.push.apple.com/test",
            p256dh: "key123",
            auth: "auth123",
            userAgent: "Mozilla/5.0"
        )
        try verifyCasing(subPayload, label: "PushSubscriptionPayload")

        let subRes = PushSubscriptionResponse(endpoint: "https://web.push.apple.com/test")
        try verifyCasing(subRes, label: "PushSubscriptionResponse")

        let unsubPayload = PushUnsubscribePayload(endpoint: "https://web.push.apple.com/test")
        try verifyCasing(unsubPayload, label: "PushUnsubscribePayload")

        let unsubRes = PushUnsubscribeResponse(removed: true)
        try verifyCasing(unsubRes, label: "PushUnsubscribeResponse")

        let testRes = PushTestResponse(delivered: 1)
        try verifyCasing(testRes, label: "PushTestResponse")
    }
}
