// Rune Weaver Core — Conversation persistence helpers for durable history.

import Foundation

extension ConversationManager {
    /// Quantizes a timestamp to whole-millisecond precision.
    static func persistedInstant(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    /// Copy safe for durable history with transient screenshot pixels removed.
    /// Keeps the content hash plus surrounding text so the audit trail can
    /// correlate the capture without retaining recoverable pixels.
    static func redactedForPersistence(_ session: ConversationSession) -> ConversationSession {
        var copy = session
        copy.messages = session.messages.map { message in
            let redacted = VisionGate.strippedContent(message.content)
            guard redacted != message.content else { return message }
            return message.withContent(redacted)
        }
        return copy
    }

    /// Deletes one persisted session without observing cancellation.
    func deletePersistedSessionUncancellable(id: UUID) async {
        guard let path = episodesDBPath else { return }
        await SQLiteSerialIO.runUncancellable {
            do {
                try SessionStoreIO.delete(sessionID: id, dbPath: path)
            } catch {
                RuneWeaverLog.stores.error("ConversationManager: Failed to uncancellably delete session \(id): \(error)")
            }
        }
    }
}
