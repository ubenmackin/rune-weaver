// Rune Weaver Core — Owner-facing assistant persona for the prompt identity block.

import Foundation

/// Tone preset folded into the prompt identity sentence.
public enum PersonaTone: String, Sendable, Codable, CaseIterable, Equatable {
    /// Short direct answers without small talk.
    case concise
    /// Warm and encouraging while staying focused. Default.
    case warm
    /// Polite professional wording without slang.
    case formal
    /// Light playful tone that never costs clarity.
    case playful
}

/// Client-side avatar accent for persona surfaces. The closed set is validated at the config
/// boundary; the value selects an accent in clients only and is intentionally absent from composed
/// prompt bytes.
public enum PersonaAvatar: String, Sendable, Codable, CaseIterable, Equatable {
    /// Violet accent. Default.
    case violet
    /// Cyan accent.
    case cyan
    /// Emerald accent.
    case emerald
    /// Rose accent.
    case rose
}

/// `[persona]` — assistant persona injected into the prompt identity line.
public struct PersonaConfig: Sendable, Codable, Equatable {
    /// How the assistant refers to itself in the prompt identity.
    public var assistantName: String
    /// Tone preset sentence appended to the identity.
    public var tone: PersonaTone
    /// Free-form owner style guidance; empty means nothing beyond the preset.
    public var style: String
    /// Owner's preferred name for the address clause; empty means none.
    public var userName: String
    /// Client-side avatar accent; never enters the prompt.
    public var avatar: PersonaAvatar

    /// Default assistant name; matches the stock identity sentence.
    public static let defaultAssistantName = "Rune Weaver"
    /// Default tone preset keeps a warm, focused posture.
    public static let defaultTone = PersonaTone.warm
    /// Default style guidance is empty: the identity line omits the clause.
    public static let defaultStyle = ""
    /// Default owner name is empty: the identity line omits the address.
    public static let defaultUserName = ""
    /// Default avatar accent.
    public static let defaultAvatar = PersonaAvatar.violet

    /// Longest accepted `assistant_name`, keeping the identity sentence short.
    public static let maxAssistantNameLength = 32
    /// Longest stored style guidance; beyond this the leading clause survives.
    public static let maxStyleLength = 2000
    /// Longest accepted owner name in the address clause.
    public static let maxUserNameLength = 64

    /// Creates a persona config.
    public init(
        assistantName: String = defaultAssistantName,
        tone: PersonaTone = defaultTone,
        style: String = defaultStyle,
        userName: String = defaultUserName,
        avatar: PersonaAvatar = defaultAvatar
    ) {
        self.assistantName = assistantName
        self.tone = tone
        self.style = style
        self.userName = userName
        self.avatar = avatar
    }

    /// Whether every prompt-affecting field sits at its stock default.
    public var isDefaultIdentity: Bool {
        assistantName == Self.defaultAssistantName
            && tone == Self.defaultTone
            && style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Length-framed canonical encoding of every persona field.
    public var canonicalCacheString: String {
        var framed = ""
        for field in [assistantName, tone.rawValue, style, userName, avatar.rawValue] {
            framed += "\(field.utf8.count):\(field)"
        }
        return framed
    }

    private enum CodingKeys: String, CodingKey {
        case assistantName
        case tone
        case style
        case userName
        case avatar
    }

    /// Decodes a persona key-by-key, applying the documented default for every omitted key and the
    /// same normalize-or-reject contract as TOML load, so a JSON payload can never land a shape the
    /// file path would refuse.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawAssistantName = try container.decodeIfPresent(String.self, forKey: .assistantName)
        assistantName = try Self.normalizedAssistantName(rawAssistantName)
        let rawTone = try container.decodeIfPresent(String.self, forKey: .tone)
        tone = try Self.normalizedTone(rawTone)
        let rawStyle = try container.decodeIfPresent(String.self, forKey: .style)
        style = Self.normalizedStyle(rawStyle)
        let rawUserName = try container.decodeIfPresent(String.self, forKey: .userName)
        userName = try Self.normalizedUserName(rawUserName)
        let rawAvatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        avatar = try Self.normalizedAvatar(rawAvatar)
    }

    /// Encodes the persona with tone and avatar as their string spellings so
    /// the JSON shape matches the TOML file shape key for key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assistantName, forKey: .assistantName)
        try container.encode(tone.rawValue, forKey: .tone)
        try container.encode(style, forKey: .style)
        try container.encode(userName, forKey: .userName)
        try container.encode(avatar.rawValue, forKey: .avatar)
    }
}
