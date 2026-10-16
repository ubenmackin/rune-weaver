// Rune Weaver Server — Persona settings patch and merge logic.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial `[persona]` patch for `PUT /settings`.
public struct PersonaUpdate: Content, Sendable, Equatable {
    /// How the assistant refers to itself in the prompt identity. Nil preserves the stored value.
    public var assistantName: String?
    /// Tone preset raw value (`concise`, `warm`, `formal`, `playful`). Nil preserves the stored value.
    public var tone: String?
    /// Free-form owner style guidance. Nil preserves the stored value.
    public var style: String?
    /// Owner's preferred name for the address clause. Nil preserves the stored value.
    public var userName: String?
    /// Avatar accent raw value (`violet`, `cyan`, `emerald`, `rose`). Nil preserves the stored value.
    public var avatar: String?

    /// Creates a partial persona patch. assistantName: Assistant display name.
    public init(
        assistantName: String? = nil,
        tone: String? = nil,
        style: String? = nil,
        userName: String? = nil,
        avatar: String? = nil
    ) {
        self.assistantName = assistantName
        self.tone = tone
        self.style = style
        self.userName = userName
        self.avatar = avatar
    }

    /// Populates a patch from a full snapshot so programmatic callers holding a complete
    /// `PersonaConfig` reuse the same merge path without hand-mapping fields.
    public init(_ config: PersonaConfig) {
        self.assistantName = config.assistantName
        self.tone = config.tone.rawValue
        self.style = config.style
        self.userName = config.userName
        self.avatar = config.avatar.rawValue
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full persona snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter persona: Complete persona snapshot.
    public init(persona: PersonaConfig) {
        self.init(persona: PersonaUpdate(persona))
    }
}

// MARK: - Persona Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial persona patch onto the stored `[persona]` section, preserving every field
    /// the request omits. A nil patch is a no-op, so a dashboard edit elsewhere never resets the
    /// owner's identity.
    func applyPersona(to persona: inout PersonaConfig) throws {
        guard let update = self.persona else { return }
        if let rawAssistantName = update.assistantName {
            persona.assistantName = try PersonaConfig.normalizedAssistantName(rawAssistantName)
        }
        if let rawTone = update.tone {
            persona.tone = try PersonaConfig.normalizedTone(rawTone)
        }
        if let rawStyle = update.style {
            persona.style = PersonaConfig.normalizedStyle(rawStyle)
        }
        if let rawUserName = update.userName {
            persona.userName = try PersonaConfig.normalizedUserName(rawUserName)
        }
        if let rawAvatar = update.avatar {
            persona.avatar = try PersonaConfig.normalizedAvatar(rawAvatar)
        }
    }
}
