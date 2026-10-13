// Rune Weaver Core Tests — Persona config defaults, decode, validation, and round-trip.
//
// Covers the additive `[persona]` table: stock defaults on an absent table,
// key-by-key decode with partial and full tables, TOML render round-trip, the
// blank-name fallback and overlong-style truncation (logged degradations), and
// the fail-closed bounds for oversized or unprintable names, oversized owner
// names, and unknown tone or avatar spellings across the TOML load, JSON
// decode, and hand-built validate paths.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Minimal `[llm]` prefix keeping config documents loadable in tests.
private let personaTestLLMPrefix = """
[llm]
default_provider = "mlx"
[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"
"""

/// Loads a config document from the shared `[llm]` prefix plus extra text.
private func loadPersonaConfig(_ extra: String) throws -> RuneWeaverConfig {
    try RuneWeaverConfig(decoding: TOMLParser.parse(personaTestLLMPrefix + extra))
}

/// Extracts the dotted field from a validation failure, failing otherwise.
private func validationField(of error: any Error) -> String? {
    guard let configError = error as? ConfigError else { return nil }
    guard case let .validationError(field, _) = configError else { return nil }
    return field
}

@Suite("PersonaConfig", .testLogCaptureBootstrap)
struct PersonaConfigTests {
    @Test
    func `Defaults carry the stock persona`() {
        let persona = PersonaConfig()
        #expect(persona.assistantName == "Rune Weaver")
        #expect(persona.tone == .warm)
        #expect(persona.style == "")
        #expect(persona.userName == "")
        #expect(persona.avatar == .violet)
        #expect(PersonaConfig.defaultAssistantName == "Rune Weaver")
        #expect(PersonaConfig.defaultTone == .warm)
        #expect(PersonaConfig.defaultAvatar == .violet)
        #expect(persona.isDefaultIdentity)
        #expect(RuneWeaverConfig.default.persona == PersonaConfig())
    }

    @Test
    func `Absent persona table decodes to defaults`() throws {
        let config = try loadPersonaConfig("")
        #expect(config.persona == PersonaConfig())
        try config.validate()
    }

    @Test
    func `Full table decodes field by field`() throws {
        let config = try loadPersonaConfig("""
        \n[persona]\nassistant_name = "Friday"\ntone = "concise"\nstyle = "Prefer tables over prose."\nuser_name = "Ada"\navatar = "cyan"\n
        """)
        #expect(config.persona.assistantName == "Friday")
        #expect(config.persona.tone == .concise)
        #expect(config.persona.style == "Prefer tables over prose.")
        #expect(config.persona.userName == "Ada")
        #expect(config.persona.avatar == .cyan)
        #expect(!config.persona.isDefaultIdentity)
        try config.validate()
    }

    @Test
    func `Partial table keeps defaults for omitted keys`() throws {
        let config = try loadPersonaConfig("\n[persona]\ntone = \"playful\"\n")
        #expect(config.persona.tone == .playful)
        #expect(config.persona.assistantName == "Rune Weaver")
        #expect(config.persona.style == "")
        #expect(config.persona.userName == "")
        #expect(config.persona.avatar == .violet)
        try config.validate()
    }

    @Test
    func `Rendered persona round-trips and reparses equal`() throws {
        var config = RuneWeaverConfig.default
        config.persona = PersonaConfig(
            assistantName: "Friday",
            tone: .formal,
            style: "British spellings.",
            userName: "Ada",
            avatar: .rose
        )
        let rendered = config.renderTOML()
        #expect(rendered.contains("[persona]"))
        #expect(rendered.contains("assistant_name = \"Friday\""))
        #expect(rendered.contains("tone = \"formal\""))
        #expect(rendered.contains("style = \"British spellings.\""))
        #expect(rendered.contains("user_name = \"Ada\""))
        #expect(rendered.contains("avatar = \"rose\""))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.persona == config.persona)
        try reparsed.validate()
    }

    @Test
    func `Blank assistant name falls back to the default with the rest of the table intact`() throws {
        let config = try loadPersonaConfig("\n[persona]\nassistant_name = \"   \"\ntone = \"formal\"\n")
        #expect(config.persona.assistantName == "Rune Weaver")
        #expect(config.persona.tone == .formal)
        try config.validate()
        // The fallback is the documented fail-soft posture: repair plus a
        // logged note. The note is behavioral, so it is pinned against the
        // captured log store rather than whatever reaches the console.
        #expect(!TestLogCapture.records(containing: "blank persona.assistant_name").isEmpty)
    }

    @Test
    func `Overlong style truncates to the documented bound`() throws {
        let long = String(repeating: "x", count: PersonaConfig.maxStyleLength + 500)
        let config = try loadPersonaConfig("\n[persona]\nstyle = \"\(long)\"\n")
        #expect(config.persona.style.count == PersonaConfig.maxStyleLength)
        #expect(config.persona.style == String(repeating: "x", count: PersonaConfig.maxStyleLength))
        try config.validate()
        // Truncation is fail-open with a logged note; assert the note landed
        // in the captured store so the owner-facing degradation is observable
        // without mirroring warning output to the test console.
        #expect(!TestLogCapture.records(containing: "persona.style exceeds").isEmpty)
    }

    @Test
    func `Unknown tone and avatar reject with the dotted field path`() throws {
        do {
            _ = try loadPersonaConfig("\n[persona]\ntone = \"salty\"\n")
            Issue.record("Expected validation failure for unknown tone")
        } catch {
            #expect(validationField(of: error) == "persona.tone")
        }
        do {
            _ = try loadPersonaConfig("\n[persona]\navatar = \"chartreuse\"\n")
            Issue.record("Expected validation failure for unknown avatar")
        } catch {
            #expect(validationField(of: error) == "persona.avatar")
        }
    }

    @Test
    func `Oversized names reject at decode and at validation`() throws {
        let longName = String(repeating: "n", count: PersonaConfig.maxAssistantNameLength + 1)
        do {
            _ = try loadPersonaConfig("\n[persona]\nassistant_name = \"\(longName)\"\n")
            Issue.record("Expected validation failure for oversized assistant name")
        } catch {
            #expect(validationField(of: error) == "persona.assistant_name")
        }
        let longUser = String(repeating: "u", count: PersonaConfig.maxUserNameLength + 1)
        do {
            _ = try loadPersonaConfig("\n[persona]\nuser_name = \"\(longUser)\"\n")
            Issue.record("Expected validation failure for oversized user name")
        } catch {
            #expect(validationField(of: error) == "persona.user_name")
        }

        // Hand-built configs that bypass decode still fail at validate, so a
        // settings write cannot persist shapes the file path would refuse.
        var handBuiltName = RuneWeaverConfig.default
        handBuiltName.persona.assistantName = longName
        do {
            try handBuiltName.validate()
            Issue.record("Expected validation failure for hand-built oversized assistant name")
        } catch {
            #expect(validationField(of: error) == "persona.assistant_name")
        }
        var handBuiltUser = RuneWeaverConfig.default
        handBuiltUser.persona.userName = longUser
        do {
            try handBuiltUser.validate()
            Issue.record("Expected validation failure for hand-built oversized user name")
        } catch {
            #expect(validationField(of: error) == "persona.user_name")
        }
    }

    @Test
    func `Non-printable assistant name rejects at validation`() throws {
        var config = RuneWeaverConfig.default
        config.persona.assistantName = "We\u{0001}aver"
        do {
            try config.validate()
            Issue.record("Expected validation failure for control character in assistant name")
        } catch {
            #expect(validationField(of: error) == "persona.assistant_name")
        }
    }

    @Test
    func `JSON shape round-trips with string tone and avatar spellings`() throws {
        let persona = PersonaConfig(
            assistantName: "Friday",
            tone: .playful,
            style: "British spellings.",
            userName: "Ada",
            avatar: .emerald
        )
        let data = try JSONEncoder().encode(persona)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"tone\":\"playful\""))
        #expect(json.contains("\"avatar\":\"emerald\""))
        #expect(json.contains("\"assistantName\""))
        #expect(json.contains("\"userName\""))
        let decoded = try JSONDecoder().decode(PersonaConfig.self, from: data)
        #expect(decoded == persona)
    }

    @Test
    func `JSON payload with unknown tone rejects with the dotted field path`() throws {
        let data = Data("{\"tone\":\"salty\"}".utf8)
        do {
            _ = try JSONDecoder().decode(PersonaConfig.self, from: data)
            Issue.record("Expected rejection for unknown tone spelling")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "persona.tone")
        }
    }

    @Test
    func `Canonical cache string differs for any persona field including the avatar`() {
        // The avatar never reaches prompt bytes, so a length-framed canonical
        // string that still differs per accent is what keeps the composer's
        // "any persona change is a cache miss" contract true.
        #expect(PersonaConfig().canonicalCacheString != PersonaConfig(avatar: .cyan).canonicalCacheString)
        #expect(PersonaConfig().canonicalCacheString != PersonaConfig(userName: "A").canonicalCacheString)
        #expect(PersonaConfig(userName: "A").canonicalCacheString != PersonaConfig(userName: "AB").canonicalCacheString)
        #expect(PersonaConfig(assistantName: "a", style: "b").canonicalCacheString != PersonaConfig(assistantName: "ab", style: "b").canonicalCacheString)
    }

    @Test
    func `Hand-built blank assistant name fails closed without repairing the stored value`() {
        var config = RuneWeaverConfig.default
        config.persona.assistantName = "   "
        do {
            try config.validate()
            Issue.record("Expected validation failure for hand-built blank assistant name")
        } catch {
            #expect(validationField(of: error) == "persona.assistant_name")
        }
        // Fail-closed without repair: the stored value stays blank so the
        // refusal is visible instead of silently rendering another identity.
        #expect(config.persona.assistantName == "   ")
        // The composer still holds the line invariant by falling back to the
        // stock identity at render, so an unvalidated compose cannot splice.
        let date = "2026-09-27"
        let prompt = SystemPromptComposer.compose(tools: [], currentDate: date, persona: config.persona)
        let legacy = SystemPromptComposer.compose(tools: [], currentDate: date)
        #expect(prompt == legacy)
        #expect(SystemPromptComposer.isComposedPrompt(prompt))
    }

    @Test
    func `Hand-built overlong style fails closed without truncating the stored value`() {
        let long = String(repeating: "x", count: PersonaConfig.maxStyleLength + 500)
        var config = RuneWeaverConfig.default
        config.persona.style = long
        do {
            try config.validate()
            Issue.record("Expected validation failure for hand-built overlong style")
        } catch {
            #expect(validationField(of: error) == "persona.style")
        }
        // Fail-closed without truncation: the stored bytes stay overlong so
        // the refusal is auditable rather than a silent clamp at check time.
        #expect(config.persona.style.count == PersonaConfig.maxStyleLength + 500)
        // The composer clamps at render so the prompt never carries the
        // overlong bytes even when validation is bypassed entirely.
        let date = "2026-09-28"
        let prompt = SystemPromptComposer.compose(tools: [], currentDate: date, persona: config.persona)
        #expect(SystemPromptComposer.isComposedPrompt(prompt))
        let expectedPrefix =
            "You are Rune Weaver, Be warm and encouraging while staying focused. "
                + String(repeating: "x", count: PersonaConfig.maxStyleLength)
        #expect(prompt.hasPrefix(expectedPrefix))
        let lines = NormalizedText.splitLines(prompt)
        #expect(lines[1] == SystemPromptComposer.composedMarker)
    }
}
