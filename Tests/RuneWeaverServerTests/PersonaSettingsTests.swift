// Rune Weaver Tests — Persona settings patch contract.
//
// Purpose: pins the `PUT /settings` persona contract at the DTO layer: a
// partial patch preserves every omitted identity field, a save without the
// `persona` key never disturbs the stored persona (the regression guard for
// the merge logic), unknown tone and avatar spellings fail closed with the
// dotted field path the route maps to a 400, the shared core normalizers
// keep their documented repair-versus-refuse split on the wire path, and a
// saved persona survives the config-file round trip so `GET /settings`
// reflects exactly what was PUT.
// Scope: settings DTO merge and validation behavior plus wire spellings;
// prompt rendering and composer-cache semantics stay with the core suites.
// Architectural role: guards the one owner surface that edits the assistant
// identity, so a route or DTO edit cannot silently reset the persona,
// persist a spelling the TOML loader would refuse, or drop the persona from
// the settings GET the dashboard renders.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

@Suite("Persona Settings Patch")
struct PersonaSettingsTests {
    /// Applies a persona patch the settings merge must refuse and returns the
    /// dotted field path from the `ConfigError` the route maps to a 400. A
    /// refused save must leave the stored persona untouched, so the helper
    /// pins the pre-apply snapshot on the way out — the same atomicity the
    /// route reports before ever touching the file.
    private func rejectedPersonaField(for update: PersonaUpdate) -> String {
        var config = RuneWeaverConfig.default
        let preserved = config.persona
        do {
            try UpdateSettingsRequest(persona: update).apply(to: &config)
            Issue.record("Expected a validation error for \(update)")
            return ""
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected a field-named validation error, got \(error)")
                return ""
            }
            #expect(config.persona == preserved)
            return field
        } catch {
            Issue.record("Expected ConfigError, got \(type(of: error))")
            return ""
        }
    }

    @Test
    func `Persona patch merges one key and preserves the rest`() throws {
        var config = RuneWeaverConfig.default
        config.persona = PersonaConfig(
            assistantName: "Friday",
            tone: .formal,
            style: "Lead with the answer.",
            userName: "Kupan",
            avatar: .cyan
        )

        // A name-only PUT must not wipe the tone preset, style guidance,
        // address clause, or accent — the partial-patch invariant.
        try UpdateSettingsRequest(persona: PersonaUpdate(assistantName: "Veda")).apply(to: &config)
        #expect(config.persona.assistantName == "Veda")
        #expect(config.persona.tone == .formal)
        #expect(config.persona.style == "Lead with the answer.")
        #expect(config.persona.userName == "Kupan")
        #expect(config.persona.avatar == .cyan)
    }

    @Test
    func `Settings update without a persona key leaves the stored persona untouched`() throws {
        var config = RuneWeaverConfig.default
        let stored = PersonaConfig(
            assistantName: "Friday",
            tone: .playful,
            style: "Dry wit.",
            userName: "Sam",
            avatar: .rose
        )
        config.persona = stored

        // An unrelated settings PUT decodes `persona` as nil, and a nil patch
        // is a full no-op — the regression guard for the merge logic.
        let request = try JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(#"{"engineName":"Kept Persona"}"#.utf8)
        )
        #expect(request.persona == nil)
        try request.apply(to: &config)
        #expect(config.engine.name == "Kept Persona")
        #expect(config.persona == stored)

        // A present-but-empty persona object merges no field either, so a
        // dashboard that sends `{}` for an untouched section cannot reset it.
        try UpdateSettingsRequest(persona: PersonaUpdate()).apply(to: &config)
        #expect(config.persona == stored)
    }

    @Test
    func `Persona wire shape decodes camelCase keys and merges partially`() throws {
        // The acceptance PUT body: a single camelCase key must land on the
        // name while every omitted field stays nil so the merge preserves it.
        let request = try JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(#"{"persona":{"assistantName":"Veda"}}"#.utf8)
        )
        #expect(request.persona?.assistantName == "Veda")
        #expect(request.persona?.tone == nil)
        #expect(request.persona?.style == nil)
        #expect(request.persona?.userName == nil)
        #expect(request.persona?.avatar == nil)

        var config = RuneWeaverConfig.default
        config.persona = PersonaConfig(tone: .concise, avatar: .emerald)
        try request.apply(to: &config)
        #expect(config.persona.assistantName == "Veda")
        #expect(config.persona.tone == .concise)
        #expect(config.persona.avatar == .emerald)
    }

    @Test
    func `Persona patch encodes camelCase only`() throws {
        // camelCase is the single canonical wire spelling.
        let camel = try JSONDecoder().decode(
            PersonaUpdate.self,
            from: Data(#"{"assistantName":"Camel","userName":"Owner"}"#.utf8)
        )
        #expect(camel.assistantName == "Camel")
        #expect(camel.userName == "Owner")

        // Encode keeps camelCase so a round-trip never invents a second
        // spelling.
        let text = try String(
            data: JSONEncoder().encode(PersonaUpdate(assistantName: "Veda", userName: "Kupan")),
            encoding: .utf8
        ) ?? ""
        #expect(text.contains("assistantName"))
        #expect(text.contains("userName"))
        #expect(!text.contains("assistant_name"))
        #expect(!text.contains("user_name"))
    }

    @Test
    func `Unknown persona enum spellings fail closed with their field paths`() {
        // The closed sets are validated at this boundary, not left to a bare
        // decode error: each unknown string must name its dotted field so
        // the route's 400 mirrors the file loader's report.
        #expect(rejectedPersonaField(for: PersonaUpdate(tone: "sarcastic")) == "persona.tone")
        #expect(rejectedPersonaField(for: PersonaUpdate(tone: "")) == "persona.tone")
        #expect(rejectedPersonaField(for: PersonaUpdate(avatar: "indigo")) == "persona.avatar")
    }

    @Test
    func `Oversized and unprintable persona names fail closed with their field paths`() {
        let longName = String(repeating: "a", count: PersonaConfig.maxAssistantNameLength + 1)
        #expect(rejectedPersonaField(for: PersonaUpdate(assistantName: longName)) == "persona.assistant_name")

        // Control characters would splice the identity sentence across prompt
        // lines, so they refuse rather than persist a broken clause.
        #expect(rejectedPersonaField(for: PersonaUpdate(assistantName: "Ve\nda")) == "persona.assistant_name")

        let longUser = String(repeating: "u", count: PersonaConfig.maxUserNameLength + 1)
        #expect(rejectedPersonaField(for: PersonaUpdate(userName: longUser)) == "persona.user_name")
    }

    @Test
    func `Repairable persona shapes normalize instead of rejecting`() throws {
        // Blank names and overlong style keep the documented core posture —
        // fallback and truncation, not refusal — so the PUT path cannot
        // drift from TOML load.
        var config = RuneWeaverConfig.default
        config.persona = PersonaConfig(assistantName: "Veda", tone: .formal)
        try UpdateSettingsRequest(persona: PersonaUpdate(assistantName: "   ")).apply(to: &config)
        #expect(config.persona.assistantName == PersonaConfig.defaultAssistantName)
        #expect(config.persona.tone == .formal)

        // Trim and lowercase ride the shared normalizers, so `WARM` saves
        // identically to `warm` like the file loader accepts it.
        try UpdateSettingsRequest(persona: PersonaUpdate(tone: " WARM ")).apply(to: &config)
        #expect(config.persona.tone == .warm)

        let longStyle = String(repeating: "s", count: PersonaConfig.maxStyleLength + 10)
        try UpdateSettingsRequest(persona: PersonaUpdate(style: longStyle)).apply(to: &config)
        #expect(config.persona.style.count == PersonaConfig.maxStyleLength)
    }

    @Test
    func `Saved persona round-trips through the config file into the settings GET`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("persona_settings_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A full snapshot PUT must persist every field through the same merge
        // the route uses and re-read intact, so the persona save is durable
        // rather than live-only, and the settings GET carries it on the wire.
        let expected = PersonaConfig(
            assistantName: "Veda",
            tone: .concise,
            style: "Lead with the answer.",
            userName: "Kupan",
            avatar: .emerald
        )
        let fileURL = tempDir.appendingPathComponent("config.toml")
        var config = RuneWeaverConfig.default
        try UpdateSettingsRequest(persona: PersonaUpdate(expected)).apply(to: &config)
        try config.validate()
        try config.save(to: fileURL)

        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.persona == expected)

        let response = SettingsResponse(config: reloaded, configPath: fileURL.path, requiresRestart: true)
        #expect(response.persona == expected)

        let payload = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(SettingsResponse.self, from: payload)
        #expect(decoded.persona == expected)
    }

    @Test
    func `SettingsResponse decodes payloads without a persona key at the stock identity`() throws {
        // Version tolerance: a GET payload from an engine that predates the
        // persona surface must decode at the stock identity instead of
        // failing the settings fetch.
        let decoded = try JSONDecoder().decode(
            SettingsResponse.self,
            from: Data(#"{"engineName":"Rune Weaver","defaultProvider":"mlx"}"#.utf8)
        )
        #expect(decoded.persona == PersonaConfig())
    }
}
