// Rune Weaver Server — Event Watcher multi-source polling and rule evaluation.

import Foundation
import Logging
import RuneWeaverCore

// MARK: - Decode Envelopes

private struct EmailWatcherItem: Decodable {
    let id: String
    let subject: String?
    let from: String?
    let snippet: String?
    let date: String?
    let mailbox: String?
    let account: String?
}

private struct EmailWatcherEnvelope: Decodable {
    let messages: [EmailWatcherItem]
}

private struct MessagesWatcherItem: Decodable {
    let id: String
    let text: String
    let date: String?
    let isFromMe: Bool?
    let sender: String?
    let chatID: String?
    let chatDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case date
        case isFromMe
        case sender
        case chatID = "chatId"
        case chatDisplayName
    }
}

private struct MessagesWatcherEnvelope: Decodable {
    let messages: [MessagesWatcherItem]
}

private struct CalendarWatcherItem: Decodable {
    let id: String
    let calendarName: String?
    let title: String
    let notes: String?
    let startDateISO: String?
    let endDateISO: String?
    let startDisplay: String?
    let endDisplay: String?
    let isAllDay: Bool?
    let location: String?
}

private struct CalendarWatcherEnvelope: Decodable {
    let events: [CalendarWatcherItem]
}

// MARK: - Event Watcher Extension

extension ServerSchedulerWorker {
    /// Minimum calendar lead time in minutes. Keeps the upcoming-event window
    /// from collapsing to an always-due scan.
    static let minCalendarLeadTimeMinutes = 5
    /// Maximum calendar lead time in minutes. Keeps the upcoming-event window
    /// bounded so one fire never sweeps far-future meetings.
    static let maxCalendarLeadTimeMinutes = 120
    /// Default calendar lead time when the stored job carries none.
    static let defaultCalendarLeadTimeMinutes = 15

    /// Evaluates an event watcher job for its configured watcher source. job:
    /// Scheduled job under evaluation.
    func evaluateEventWatcherJob(job: SchedulerJob, now: Date) async -> [SchedulerRunResult]? {
        switch job.watcherSource {
        case .calendar:
            return await evaluateCalendarWatcher(job: job, now: now)
        case .messages:
            return await evaluateMessagesWatcher(job: job, now: now)
        case .email:
            return await evaluateEmailWatcher(job: job, now: now)
        case nil:
            if job.hasPollTrigger {
                return await evaluateEmailWatcher(job: job, now: now)
            }
            return nil
        }
    }

    // MARK: - Direct Tool Execution

    /// Resolves direct tool arguments by substituting placeholders and ensuring required fields exist.
    private func resolveDirectToolArguments(
        template: String,
        toolName: String,
        eventID: String,
        account: String? = nil,
        sender: String? = nil,
        subject: String? = nil
    ) -> String {
        var resolved = template
            .replacingOccurrences(of: "{{id}}", with: eventID)
            .replacingOccurrences(of: "{{sender}}", with: sender ?? "")
            .replacingOccurrences(of: "{{subject}}", with: subject ?? "")
            .replacingOccurrences(of: "{{account}}", with: account ?? "")

        if let data = resolved.data(using: .utf8),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if toolName == "email.move" {
                if json["id"] == nil {
                    json["id"] = eventID
                }
                if json["account"] == nil, let account, !account.isEmpty {
                    json["account"] = account
                }
            } else if toolName == "calendar.delete" {
                if json["eventID"] == nil, json["eventId"] == nil, json["id"] == nil {
                    json["eventID"] = eventID
                }
            }
            if let updatedData = try? JSONSerialization.data(withJSONObject: json),
               let updatedStr = String(data: updatedData, encoding: .utf8)
            {
                resolved = updatedStr
            }
        }
        return resolved
    }

    /// Executes a direct tool action bypassing LLM inference.
    private func executeDirectToolAction(
        job: SchedulerJob,
        rule: EventRule,
        toolName: String,
        argumentsJSON: String,
        reason: SchedulerFireReason
    ) async -> SchedulerRunResult {
        let startTime = Date()
        guard EventRuleAction.isAllowedDirectTool(toolName) else {
            // Fail closed before locking or touching the tool bus: persisted
            // rows may predate validation, so an unknown fast-path name never
            // executes and instead settles as an audited error run.
            let sessionID = await makeSchedulerRunSession(job: job, startTime: startTime, conversations: conversations)
            let detail = "Rejected direct tool '\(toolName)' for rule '\(rule.name)': not allowlisted"
            let initialEntry = await runs.append(
                kind: "scheduler",
                status: "running",
                message: "[\(rule.name)] Direct action: \(toolName)",
                jobID: job.id,
                sessionID: sessionID,
                durationMs: 0
            )
            await hub.broadcastRun(initialEntry)
            let finishedAt = Date()
            let durationMs = Int(finishedAt.timeIntervalSince(startTime) * 1000)
            if let entry = await runs.update(
                id: initialEntry.id,
                status: "error",
                response: detail,
                totalTokens: 0,
                durationMs: durationMs
            ) {
                await hub.broadcastRun(entry)
            }
            await logger?("Scheduler rejected '\(job.name)' rule '\(rule.name)' direct \(toolName): not allowlisted")
            return SchedulerRunResult(
                jobName: job.name,
                sessionID: sessionID,
                fired: true,
                errorMessage: detail,
                fireReason: reason,
                startedAt: startTime,
                finishedAt: finishedAt
            )
        }
        guard await runLock.tryAcquire(id: job.id, name: job.name) else {
            return await recordJobSkipped(job: job, startTime: startTime)
        }

        let sessionID = await makeSchedulerRunSession(job: job, startTime: startTime, conversations: conversations)
        let initialEntry = await runs.append(
            kind: "scheduler",
            status: "running",
            message: "[\(rule.name)] Direct action: \(toolName)",
            jobID: job.id,
            sessionID: sessionID,
            durationMs: 0
        )
        await hub.broadcastRun(initialEntry)

        let input = ToolInput(toolName: toolName, argumentsJSON: argumentsJSON)
        let toolResult = await toolBus.execute(toolCall: input, context: ToolContext(conversationID: sessionID))

        let finishedAt = Date()
        let durationMs = Int(finishedAt.timeIntervalSince(startTime) * 1000)
        let status = toolResult.isError ? "error" : "ok"

        let action = ToolAction(toolName: toolName, callID: input.callID, argumentsJSON: argumentsJSON, result: toolResult)
        if let entry = await runs.update(
            id: initialEntry.id,
            status: status,
            response: toolResult.content,
            toolActions: [action],
            totalTokens: 0,
            durationMs: durationMs
        ) {
            await hub.broadcastRun(entry)
        }

        if !toolResult.isError {
            await scheduler.recordSuccessfulRun(id: job.id, endedAt: finishedAt)
        }

        let preview = String(toolResult.content.prefix(100))
        await logger?("Scheduler fired '\(job.name)' rule '\(rule.name)' (\(reason.displayName)) -> direct \(toolName): \(preview)")

        await runLock.release(id: job.id, name: job.name)

        return SchedulerRunResult(
            jobName: job.name,
            sessionID: sessionID,
            fired: true,
            responseText: toolResult.content,
            fireReason: reason,
            startedAt: startTime,
            finishedAt: finishedAt
        )
    }

    // MARK: - Email Watcher

    /// Evaluates email watcher rules or legacy email poll triggering.
    private func evaluateEmailWatcher(job: SchedulerJob, now: Date) async -> [SchedulerRunResult]? {
        let rule = job.pollRule ?? EmailPollRule(account: job.pollAccount ?? "default")
        if let last = lastPollCheck[job.id] {
            let elapsed = now.timeIntervalSince(last)
            // Defensive clamp keeps stored rows that predate validation from hot-looping the mailbox.
            let interval = Double(EmailPollRule.clampedPollIntervalSeconds(rule.pollIntervalSeconds))
            if elapsed < interval {
                return nil
            }
        }
        lastPollCheck[job.id] = now

        let items: [EmailWatcherItem]
        if let customChecker = pollChecker {
            let ids = await customChecker(rule)
            items = ids.map {
                EmailWatcherItem(
                    id: $0,
                    subject: "",
                    from: "",
                    snippet: "",
                    date: "",
                    mailbox: rule.trimmedMailbox ?? "INBOX",
                    account: rule.trimmedAccount
                )
            }
        } else {
            items = await performEmailWatcherSearch(rule: rule)
        }

        let currentIDs = Set(items.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard let seen = seenPollIDs[job.id] else {
            seenPollIDs[job.id] = currentIDs
            return nil
        }

        let fresh = items.filter { !seen.contains($0.id) }
        seenPollIDs[job.id] = seen.union(currentIDs)
        guard !fresh.isEmpty else { return nil }

        // Fall back to legacy single-prompt behavior if no rules are configured
        let configuredRules = (job.rules ?? []).filter(\.enabled)
        if configuredRules.isEmpty {
            let reason = SchedulerFireReason.emailArrived(account: rule.trimmedAccount, count: fresh.count)
            let outcome = await executeJob(job, reason: reason)
            return [outcome]
        }

        var results: [SchedulerRunResult] = []
        for item in fresh {
            for eventRule in configuredRules {
                let matches = eventRule.condition.matches(
                    emailSender: item.from ?? "",
                    emailSubject: item.subject ?? "",
                    emailBody: item.snippet ?? ""
                )
                guard matches else { continue }

                let reason = SchedulerFireReason.emailArrived(account: item.account ?? rule.trimmedAccount, count: 1)
                switch eventRule.action {
                case let .directTool(toolName, argumentsJSON):
                    let resolvedArgs = resolveDirectToolArguments(
                        template: argumentsJSON,
                        toolName: toolName,
                        eventID: item.id,
                        account: item.account ?? rule.trimmedAccount,
                        sender: item.from,
                        subject: item.subject
                    )
                    let directOutcome = await executeDirectToolAction(
                        job: job,
                        rule: eventRule,
                        toolName: toolName,
                        argumentsJSON: resolvedArgs,
                        reason: reason
                    )
                    results.append(directOutcome)
                case let .agentPrompt(promptText):
                    let context = """
                    [Event Trigger: Email Arrival]
                    From: \(item.from ?? "Unknown")
                    Subject: \(item.subject ?? "(No Subject)")
                    Mailbox: \(item.mailbox ?? "INBOX")
                    Date: \(item.date ?? "")
                    Message ID: \(item.id)
                    Snippet: \(item.snippet ?? "")

                    \(promptText)
                    """
                    let agentOutcome = await executeJob(
                        job,
                        reason: reason,
                        promptOverride: context,
                        ruleName: eventRule.name
                    )
                    results.append(agentOutcome)
                }

                if eventRule.stopProcessing {
                    break
                }
            }
        }
        return results.isEmpty ? nil : results
    }

    private func performEmailWatcherSearch(rule: EmailPollRule) async -> [EmailWatcherItem] {
        var args: [String: Any] = [
            "account": rule.trimmedAccount,
            "query": rule.query,
            "limit": rule.limit
        ]
        if let mailbox = rule.trimmedMailbox {
            args["mailbox"] = mailbox
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8)
        else { return [] }

        let result = await toolBus.execute(
            toolCall: ToolInput(toolName: "email.search", argumentsJSON: json),
            context: ToolContext(conversationID: UUID())
        )
        guard !result.isError,
              let contentData = result.content.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(EmailWatcherEnvelope.self, from: contentData)
        else { return [] }

        return envelope.messages
    }

    // MARK: - Messages Watcher

    /// Evaluates Apple Messages incoming messages and executes matched rules.
    private func evaluateMessagesWatcher(job: SchedulerJob, now: Date) async -> [SchedulerRunResult]? {
        // Defensive clamp keeps stored rows that predate validation from hot-looping the message store.
        let interval = Double(EmailPollRule.clampedPollIntervalSeconds(job.pollIntervalSeconds ?? 60))
        if let last = lastPollCheck[job.id] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < interval {
                return nil
            }
        }
        lastPollCheck[job.id] = now

        let items = await performMessagesWatcherSearch()
        let currentIDs = Set(items.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard let seen = seenPollIDs[job.id] else {
            seenPollIDs[job.id] = currentIDs
            return nil
        }

        // Only evaluate inbound messages (isFromMe != true)
        let fresh = items.filter { !seen.contains($0.id) && $0.isFromMe != true }
        seenPollIDs[job.id] = seen.union(currentIDs)
        guard !fresh.isEmpty else { return nil }

        let configuredRules = (job.rules ?? []).filter(\.enabled)
        if configuredRules.isEmpty {
            let reason = SchedulerFireReason.messagesArrived(count: fresh.count)
            let outcome = await executeJob(job, reason: reason)
            return [outcome]
        }

        var results: [SchedulerRunResult] = []
        for item in fresh {
            let isGroupChat = (item.chatID?.hasPrefix("chat") == true) || !(item.chatDisplayName?.isEmpty ?? true)
            for eventRule in configuredRules {
                let matches = eventRule.condition.matches(
                    messageSender: item.sender ?? "",
                    messageText: item.text,
                    isGroupChat: isGroupChat
                )
                guard matches else { continue }

                let reason = SchedulerFireReason.messagesArrived(count: 1)
                switch eventRule.action {
                case let .directTool(toolName, argumentsJSON):
                    let resolvedArgs = resolveDirectToolArguments(
                        template: argumentsJSON,
                        toolName: toolName,
                        eventID: item.id,
                        sender: item.sender,
                        subject: item.text
                    )
                    let directOutcome = await executeDirectToolAction(
                        job: job,
                        rule: eventRule,
                        toolName: toolName,
                        argumentsJSON: resolvedArgs,
                        reason: reason
                    )
                    results.append(directOutcome)
                case let .agentPrompt(promptText):
                    let chatName = item.chatDisplayName ?? item.chatID ?? "Direct"
                    let context = """
                    [Event Trigger: Message Received]
                    From: \(item.sender ?? "Unknown")
                    Chat: \(chatName)
                    Date: \(item.date ?? "")
                    Message: \(item.text)

                    \(promptText)
                    """
                    let agentOutcome = await executeJob(
                        job,
                        reason: reason,
                        promptOverride: context,
                        ruleName: eventRule.name
                    )
                    results.append(agentOutcome)
                }

                if eventRule.stopProcessing {
                    break
                }
            }
        }
        return results.isEmpty ? nil : results
    }

    private func performMessagesWatcherSearch() async -> [MessagesWatcherItem] {
        let args: [String: Any] = ["limit": 20]
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8)
        else { return [] }

        let result = await toolBus.execute(
            toolCall: ToolInput(toolName: "messages.search", argumentsJSON: json),
            context: ToolContext(conversationID: UUID())
        )
        guard !result.isError,
              let contentData = result.content.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(MessagesWatcherEnvelope.self, from: contentData)
        else { return [] }

        return envelope.messages
    }

    // MARK: - Calendar Watcher

    /// Evaluates upcoming Calendar meetings within the lead time window.
    private func evaluateCalendarWatcher(job: SchedulerJob, now: Date) async -> [SchedulerRunResult]? {
        // Defensive clamp keeps stored rows that predate validation from hot-looping the calendar store.
        let interval = Double(EmailPollRule.clampedPollIntervalSeconds(job.pollIntervalSeconds ?? 60))
        if let last = lastPollCheck[job.id] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < interval {
                return nil
            }
        }
        lastPollCheck[job.id] = now

        // Stored rows may predate validation, so clamp at use to keep the
        // upcoming-event window inside the supported range.
        let rawLeadMinutes = job.calendarLeadTimeMinutes ?? Self.defaultCalendarLeadTimeMinutes
        let leadMinutes = min(max(rawLeadMinutes, Self.minCalendarLeadTimeMinutes), Self.maxCalendarLeadTimeMinutes)
        let until = now.addingTimeInterval(Double(leadMinutes * 60))
        let isoFormatter = ISO8601DateFormatter()
        let sinceStr = isoFormatter.string(from: now)
        let untilStr = isoFormatter.string(from: until)

        let events = await performCalendarWatcherSearch(since: sinceStr, until: untilStr, calendarNames: job.calendarNames)
        guard !events.isEmpty else { return nil }

        var seen = seenPollIDs[job.id] ?? Set<String>()
        var results: [SchedulerRunResult] = []
        let configuredRules = (job.rules ?? []).filter(\.enabled)

        for event in events {
            let instanceKey = "\(event.id)_\(event.startDateISO ?? "")"
            if seen.contains(instanceKey) {
                continue
            }
            seen.insert(instanceKey)

            let reason = SchedulerFireReason.calendarUpcoming(title: event.title, eventID: event.id)

            if configuredRules.isEmpty {
                let context = """
                [Event Trigger: Upcoming Calendar Event]
                Meeting: \(event.title)
                Start: \(event.startDisplay ?? event.startDateISO ?? "")
                End: \(event.endDisplay ?? event.endDateISO ?? "")
                Location: \(event.location ?? "None")
                Calendar: \(event.calendarName ?? "Default")
                Notes: \(event.notes ?? "")

                \(job.prompt)
                """
                let outcome = await executeJob(job, reason: reason, promptOverride: context)
                results.append(outcome)
                continue
            }

            for eventRule in configuredRules {
                let matches = eventRule.condition.matches(
                    calendarTitle: event.title,
                    calendarName: event.calendarName ?? "",
                    calendarLocation: event.location ?? "",
                    calendarNotes: event.notes,
                    isAllDay: event.isAllDay ?? false
                )
                guard matches else { continue }

                switch eventRule.action {
                case let .directTool(toolName, argumentsJSON):
                    let resolvedArgs = resolveDirectToolArguments(
                        template: argumentsJSON,
                        toolName: toolName,
                        eventID: event.id,
                        sender: event.calendarName,
                        subject: event.title
                    )
                    let directOutcome = await executeDirectToolAction(
                        job: job,
                        rule: eventRule,
                        toolName: toolName,
                        argumentsJSON: resolvedArgs,
                        reason: reason
                    )
                    results.append(directOutcome)
                case let .agentPrompt(promptText):
                    let context = """
                    [Event Trigger: Upcoming Calendar Event]
                    Meeting: \(event.title)
                    Start: \(event.startDisplay ?? event.startDateISO ?? "")
                    End: \(event.endDisplay ?? event.endDateISO ?? "")
                    Location: \(event.location ?? "None")
                    Calendar: \(event.calendarName ?? "Default")
                    Notes: \(event.notes ?? "")

                    \(promptText)
                    """
                    let agentOutcome = await executeJob(
                        job,
                        reason: reason,
                        promptOverride: context,
                        ruleName: eventRule.name
                    )
                    results.append(agentOutcome)
                }

                if eventRule.stopProcessing {
                    break
                }
            }
        }

        seenPollIDs[job.id] = seen
        return results.isEmpty ? nil : results
    }

    private func performCalendarWatcherSearch(since: String, until: String, calendarNames: [String]?) async -> [CalendarWatcherItem] {
        var args: [String: Any] = [
            "since": since,
            "until": until,
            "limit": 50
        ]
        if let calendarNames, !calendarNames.isEmpty {
            args["calendarNames"] = calendarNames
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8)
        else { return [] }

        let result = await toolBus.execute(
            toolCall: ToolInput(toolName: "calendar.search", argumentsJSON: json),
            context: ToolContext(conversationID: UUID())
        )
        guard !result.isError,
              let contentData = result.content.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CalendarWatcherEnvelope.self, from: contentData)
        else { return [] }

        return envelope.events
    }
}
