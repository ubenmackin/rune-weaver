// Rune Weaver Server — Persona settings patch and merge logic.
//
// Lives beside its DTO like the goals and ideas patches, keeping
// `ServerDTOs.swift` within its file-length lint budget. The partial
// `[persona]` patch for `PUT /settings` and the merge helper stay
// single-sourced: the closed tone/avatar sets, name and style bounds, and
// the normalize-or-reject posture are owned by the core validation layer
// (`PersonaConfig` shared normalizers), and this file only routes wire
// strings through them so the settings PUT and the TOML loader can never
// drift on fields or messages. The persona is boot-held: the running
// orchestrator composes its identity prompt from the config captured at
// boot, so a persona save advertises a restart like `[goals]` and
// `[proactive]` do rather than silently claiming a live swap.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial `[persona]` patch for `PUT /settings`.
///
/// Every field stays optional so a request carrying only one key leaves the
/// rest of the stored persona untouched instead of resetting it — a
/// name-only PUT never wipes the owner's tone, style guidance, address
/// clause, or accent. Tone and avatar ride as raw strings rather than the
/// closed enums so an unknown spelling fails with the same clear 400 naming
/// the dotted field path that the `[proactive] mode` patch reports, instead
/// of a bare decode error with no field. Resolution against the closed sets
/// happens in the merge helper through the shared core normalizers.
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

    /// Creates a partial persona patch.
    /// - Parameters:
    ///   - assistantName: Assistant display name.
    ///   - tone: Tone preset raw value.
    ///   - style: Owner style guidance.
    ///   - userName: Owner's preferred name.
    ///   - avatar: Avatar accent raw value.
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

    /// Populates a patch from a full snapshot so programmatic callers holding a
    /// complete `PersonaConfig` reuse the same merge path without hand-mapping
    /// fields. Tone and avatar land as their raw spellings, which the merge
    /// re-validates — a snapshot can never smuggle a shape the file loader
    /// would refuse.
    /// - Parameter config: Complete persona snapshot.
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
    /// Merges a partial persona patch onto the stored `[persona]` section,
    /// preserving every field the request omits. A nil patch is a no-op, so a
    /// dashboard edit elsewhere never resets the owner's identity.
    ///
    /// Each present key is normalized through the shared core normalizers —
    /// the same contract TOML load applies — so the PUT and the file can never
    /// disagree on fields or messages: an unknown tone or avatar spelling
    /// throws fail-closed with its dotted field path (the route maps
    /// `ConfigError` to a 400), an oversized or unprintable assistant name
    /// and an oversized owner name throw likewise, while a blank assistant
    /// name falls back to the stock identity and overlong style guidance
    /// truncates, both with a logged note — the documented repairable-shape
    /// posture. Trim and lowercase normalization of the enum spellings rides
    /// the normalizers too, so `WARM` saves identically to `warm`.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the persona-specific logic lives beside its DTO.
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
