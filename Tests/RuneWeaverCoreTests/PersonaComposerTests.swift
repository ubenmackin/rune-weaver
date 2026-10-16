// Rune Weaver Core Tests — Persona injection into the composed system prompt.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Persona Composer")
struct PersonaComposerTests {
    /// The exact expected prefix of today's prompt, pasted from the composer:
    /// the legacy identity line plus the position-anchored provenance marker.
    private static let legacyPrefix = """
    You are Rune Weaver, a helpful personal assistant across mail, memory, files, and the web.
    \(SystemPromptComposer.composedMarker)
    """

    @Test
    func `Default persona keeps the legacy prompt prefix byte identical`() {
        let date = "2026-09-18"
        // Pasted expectation: today's prompt opens with this exact text, so a
        // persona-less (or stock-persona) compose must not drift a single byte.
        let legacy = SystemPromptComposer.compose(tools: [], currentDate: date)
        #expect(legacy.hasPrefix(Self.legacyPrefix + "\n"))
        let stock = SystemPromptComposer.compose(tools: [], currentDate: date, persona: PersonaConfig())
        #expect(legacy == stock)
        #expect(SystemPromptComposer.isComposedPrompt(stock))
        let scheduled = SystemPromptComposer.composeScheduled(tools: [], currentDate: date)
        #expect(scheduled.hasPrefix(Self.legacyPrefix + "\n"))
        #expect(scheduled.contains("Scheduled task guidance:"))
    }

    @Test
    func `Custom persona rewrites only the identity line`() {
        let date = "2026-09-18"
        let persona = PersonaConfig(
            assistantName: "Friday",
            tone: .concise,
            style: "Prefer tables over prose.",
            userName: "Ada",
            avatar: .cyan
        )
        let prompt = SystemPromptComposer.compose(tools: [], currentDate: date, persona: persona)
        let expectedLine = "You are Friday, Keep replies short and direct; no small talk. "
            + "Prefer tables over prose. The owner's preferred name is Ada, use it sparingly and naturally."
        // The block stays a single line so the provenance marker remains on line two.
        #expect(prompt.hasPrefix(expectedLine + "\n" + SystemPromptComposer.composedMarker + "\n"))
        #expect(SystemPromptComposer.isComposedPrompt(prompt))
        #expect(!prompt.contains("a helpful personal assistant"))
        #expect(prompt.contains("Tool-use policy:"))
        #expect(prompt.contains("Current date: \(date)"))
        // The avatar is a client-side accent and never reaches prompt bytes.
        #expect(!prompt.contains("cyan"))
    }

    @Test
    func `Style and owner name clauses appear only when set`() {
        let date = "2026-09-19"
        let styleOnly = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(style: "Always cite file paths.")
        )
        #expect(styleOnly.contains("You are Rune Weaver, Be warm and encouraging while staying focused. Always cite file paths."))
        #expect(!styleOnly.contains("preferred name"))
        let nameOnly = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(userName: "Grace")
        )
        #expect(nameOnly.contains("You are Rune Weaver, Be warm and encouraging while staying focused."))
        #expect(nameOnly.contains("The owner's preferred name is Grace, use it sparingly and naturally."))
    }

    @Test
    func `Every tone preset contributes its exact static sentence`() {
        // Sentences are pinned as literals here so the composer's wording
        // cannot drift unnoticed through a shared constant rename.
        #expect(SystemPromptComposer.presetSentence(for: .concise) == "Keep replies short and direct; no small talk.")
        #expect(SystemPromptComposer.presetSentence(for: .warm) == "Be warm and encouraging while staying focused.")
        #expect(SystemPromptComposer.presetSentence(for: .formal) == "Be polite and professional; avoid slang.")
        #expect(SystemPromptComposer.presetSentence(for: .playful) == "A light, playful touch is welcome; never at the expense of clarity.")
        for tone in PersonaTone.allCases {
            let prompt = SystemPromptComposer.compose(
                tools: [],
                currentDate: "2026-09-20",
                persona: PersonaConfig(assistantName: "Friday", tone: tone)
            )
            #expect(prompt.contains("You are Friday, " + SystemPromptComposer.presetSentence(for: tone)))
        }
    }

    @Test
    func `Cache key carries the persona so any change misses`() {
        let date = "2026-09-21"
        let base = SystemPromptComposer.compose(tools: [], currentDate: date)
        let renamed = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(assistantName: "Friday")
        )
        // Same date and branch with a different persona must not return the
        // cached stock prompt: the custom render has to carry the custom name.
        #expect(base != renamed)
        #expect(renamed.contains("You are Friday, Be warm and encouraging while staying focused."))
        let repeated = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(assistantName: "Friday")
        )
        #expect(repeated == renamed)
        let toneSwap = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(assistantName: "Friday", tone: .formal)
        )
        #expect(toneSwap != renamed)
        #expect(toneSwap.contains("Be polite and professional; avoid slang."))
        let scheduledSwap = SystemPromptComposer.composeScheduled(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(assistantName: "Friday", tone: .playful)
        )
        #expect(scheduledSwap.contains("You are Friday, A light, playful touch is welcome; never at the expense of clarity."))
        #expect(scheduledSwap.contains("Scheduled task guidance:"))
    }

    @Test
    func `Byte audit measures the persona prompt without tool text`() {
        let date = "2026-09-22"
        let persona = PersonaConfig(assistantName: "Friday", tone: .formal, style: "No emoji.")
        let audit = SystemPromptComposer.byteAudit(tools: [], currentDate: date, persona: persona)
        #expect(audit.totalBytes == SystemPromptComposer.compose(tools: [], currentDate: date, persona: persona).utf8.count)
        #expect(audit.perTool.isEmpty)
    }

    @Test
    func `Style carrying line breaks and control characters composes to exactly one clean line`() {
        let date = "2026-09-23"
        let legacy = SystemPromptComposer.compose(tools: [], currentDate: date)
        let prompt = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(style: "Prefer tables.\n\u{0000}\u{0007}Never use emoji.\r\nBold where unsure.\u{001F}")
        )
        // The injection point squashes the owner copy through the shared
        // scrubber: every folded line break becomes one space and every
        // control byte is dropped, so the guidance survives as one clean clause.
        #expect(prompt.hasPrefix(
            "You are Rune Weaver, Be warm and encouraging while staying focused. "
                + "Prefer tables. Never use emoji. Bold where unsure."
        ))
        // Squashing can neither add a prompt line nor leave invisible bytes in
        // the identity text: the block stays one line with the provenance
        // marker still anchored on line two.
        let lines = NormalizedText.splitLines(prompt)
        #expect(lines.count == NormalizedText.splitLines(legacy).count)
        #expect(lines[0].unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
        #expect(SystemPromptComposer.isComposedPrompt(prompt))
    }

    @Test
    func `Owner name carrying line breaks and control characters composes to one clean clause`() {
        let date = "2026-09-24"
        let legacy = SystemPromptComposer.compose(tools: [], currentDate: date)
        let prompt = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(userName: "Ada\n\u{0002}Lovelace\u{007F}")
        )
        #expect(prompt.contains("The owner's preferred name is Ada Lovelace, use it sparingly and naturally."))
        let lines = NormalizedText.splitLines(prompt)
        #expect(lines.count == NormalizedText.splitLines(legacy).count)
        #expect(lines[0].unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
        #expect(SystemPromptComposer.isComposedPrompt(prompt))
    }

    @Test
    func `Control-only persona copy collapses to absent clauses and the legacy bytes`() {
        let date = "2026-09-25"
        let legacy = SystemPromptComposer.compose(tools: [], currentDate: date)
        let noise = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(style: "\n\u{0001}\u{000B}\r", userName: "\u{0000}\u{007F}")
        )
        // Sanitization is a no-op on the empty defaults, and copy that holds nothing after the
        // scrub reads as absent through the shared absence agreement, so a noise-only persona
        // renders today's prompt exactly rather than a blank-clause variant of the custom identity.
        #expect(noise == legacy)
        #expect(SystemPromptComposer.isComposedPrompt(noise))
    }

    @Test
    func `Cache key canonicalizes the sanitized persona so a scrubbed twin shares its bytes`() {
        let date = "2026-09-26"
        let dirty = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(
                assistantName: "Friday",
                style: "Prefer tables\nover prose.",
                userName: "Ada\u{0007} Lovelace"
            )
        )
        let cleanTwin = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(
                assistantName: "Friday",
                style: "Prefer tables over prose.",
                userName: "Ada Lovelace"
            )
        )
        // Sanitizing before the persona enters the cache-key computation means
        // the digest and the identity line carry the same bytes, so a dirty
        // value and its scrubbed twin share one prompt and one cache slot.
        #expect(dirty == cleanTwin)
        // Already-clean copy passes the scrubber untouched, so established
        // personas keep their exact cache keys and prompt bytes unchanged.
        #expect(NormalizedText.singleLineSanitized("") == "")
        #expect(NormalizedText.singleLineSanitized("Prefer tables over prose.") == "Prefer tables over prose.")
        #expect(cleanTwin.hasPrefix("You are Friday, Be warm and encouraging while staying focused. Prefer tables over prose."))
    }

    @Test
    func `Assistant name carrying line breaks and control characters composes to one clean line`() {
        let date = "2026-09-27"
        let legacy = SystemPromptComposer.compose(tools: [], currentDate: date)
        let prompt = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(assistantName: "Evil\nName\u{0001}\u{007F}")
        )
        // The shared scrubber folds the break to a space and drops invisible
        // bytes at both the cache-key projection and the injection point, so
        // the identity survives as one printable clause.
        #expect(prompt.hasPrefix("You are Evil Name, Be warm and encouraging while staying focused."))
        // No splice can move the provenance marker: the block stays one line
        // with the same line count as the stock prompt.
        let lines = NormalizedText.splitLines(prompt)
        #expect(lines.count == NormalizedText.splitLines(legacy).count)
        #expect(lines[0].unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
        #expect(SystemPromptComposer.isComposedPrompt(prompt))
        // Cache-key bytes equal rendered bytes: the dirty value shares its
        // slot with the already-clean twin instead of claiming a second entry.
        let cleanTwin = SystemPromptComposer.compose(
            tools: [],
            currentDate: date,
            persona: PersonaConfig(assistantName: "Evil Name")
        )
        #expect(prompt == cleanTwin)
    }
}
