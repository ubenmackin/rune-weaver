// Rune Weaver Tools — Service-aware AppleScript transport for Messages sends.

import Foundation
import RuneWeaverCore

#if canImport(SQLite3)
    import SQLite3
#endif

// MARK: - Script builder

/// Builds the AppleScript handed to `/usr/bin/osascript` for one message.
public enum MessagesAppleScriptSend {
    /// Builds the complete send script for one handle and body.
    public static func script(handle: String, text: String, service: String?) -> String {
        let escapedHandle = ProductionMessagesGateway.escapeAppleScriptString(handle)
        let escapedText = ProductionMessagesGateway.escapeAppleScriptString(text)
        // Lowercased so a database row spelling ("imessage") still targets the transport it names;
        // only the two known transports get a targeted script, and everything else keeps the
        // recovery fallback rather than guessing at an account that may not exist.
        switch service?.lowercased() {
        case "imessage":
            return """
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant "\(escapedHandle)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """
        case "sms":
            return """
            tell application "Messages"
                set targetService to 1st account whose service type = SMS
                set targetBuddy to participant "\(escapedHandle)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """
        default:
            return """
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                try
                    set targetBuddy to participant "\(escapedHandle)" of targetService
                    send "\(escapedText)" to targetBuddy
                on error
                    send "\(escapedText)" to participant "\(escapedHandle)"
                end try
            end tell
            """
        }
    }
}

// MARK: - Error mapping

/// Translates an `osascript` failure into the owner-facing send error.
public enum MessagesAppleScriptErrorMapping {
    /// Maps a non-zero `osascript` exit to a typed send error. exitCode: Child exit
    /// status, used when stderr carries no detail.
    public static func map(exitCode: Int32, stderr: String) -> MessagesToolError {
        let lowered = stderr.lowercased()
        if lowered.contains("-1743") || lowered.contains("not authorized") {
            return .automationDenied(
                "Automation permission for Messages is required; grant it in System Settings -> Privacy & Security -> Automation."
            )
        }
        if lowered.contains("-1728") {
            return .recipientUnresolved("Messages could not resolve the recipient handle.")
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .scriptFailed(trimmed.isEmpty ? "Exit code \(exitCode)" : trimmed)
    }
}

// MARK: - Delivery confirmation

#if canImport(SQLite3)
    /// Confirms a just-sent message by finding it in the owner's outgoing history. Confirmation is
    /// evidence, not a retry: Messages has already accepted the send, so this only reads.
    enum MessagesSendConfirmation {
        /// Grace subtracted from the observation start so an outgoing row
        /// written moments before confirmation began still falls in the window.
        static let lookbackSeconds: TimeInterval = 5
        /// Outgoing rows read per attempt; only the handle's presence matters.
        static let rowLimit = 20

        /// Polls outgoing history until a message to `recipient` appears.
        /// chatDatabasePath: Live `chat.db` path; `~` is expanded by the snapshotter.
        static func confirm(
            chatDatabasePath: String,
            recipient: String,
            attempts: Int = 3,
            intervalSeconds: Double = 0.75
        ) async -> Bool? {
            guard attempts > 0, let recipientKey = MessageRecipientNameNormalizer.handleKey(recipient) else {
                return false
            }
            let since = Date().addingTimeInterval(-Self.lookbackSeconds)
            for attempt in 0 ..< attempts {
                if attempt > 0 {
                    guard await pause(seconds: intervalSeconds) else {
                        // The turn was cancelled; delivery is unknown, not
                        // disproven, so report no verdict instead of a false one.
                        return nil
                    }
                }
                switch readEvidence(chatDatabasePath: chatDatabasePath, recipientKey: recipientKey, since: since) {
                case .matched:
                    return true
                case .absent:
                    continue
                case .unreadable:
                    return nil
                }
            }
            return false
        }

        /// One attempt's read outcome, kept separate so the loop owns retries
        /// while this helper owns snapshot lifetime and evidence matching.
        private enum Evidence {
            /// A row for the recipient's handle key is present.
            case matched
            /// The database was read and held no matching row.
            case absent
            /// The database could not be snapshotted, opened, or queried.
            case unreadable
        }

        /// Reads one fresh snapshot and matches outgoing rows by handle key.
        private static func readEvidence(chatDatabasePath: String, recipientKey: String, since: Date) -> Evidence {
            let directory: URL
            do {
                directory = try MessagesIndexer.snapshotDatabase(chatDatabasePath: chatDatabasePath)
            } catch {
                return .unreadable
            }
            defer { try? FileManager.default.removeItem(at: directory) }
            let snapshotPath = directory.appendingPathComponent("chat.db").path
            let handle: OpaquePointer
            do {
                handle = try MessagesIndexer.openHandle(snapshotPath: snapshotPath)
            } catch {
                return .unreadable
            }
            defer { sqlite3_close(handle) }
            let rows: [MessageOutgoingRow]
            do {
                rows = try MessagesDatabaseIO.recentOutgoingHandles(handle: handle, since: since, limit: Self.rowLimit)
            } catch {
                return .unreadable
            }
            return rows.contains { MessageRecipientNameNormalizer.handleKey($0.handle) == recipientKey } ? .matched : .absent
        }

        /// Sleeps between polls, reporting cancellation instead of throwing.
        /// - Parameter seconds: Delay length; clamped so wild values cannot trap conversion.
        private static func pause(seconds: Double) async -> Bool {
            let clamped = min(max(0, seconds), 60)
            do {
                try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                return true
            } catch {
                return false
            }
        }
    }
#endif
