// Rune Weaver Core Tests — Proactive surfacing gate decision coverage.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("OutcomeGate")
struct OutcomeGateTests {
    private func event(kind: ProactiveEventKind, title: String = "Morning digest", outcome: String = "Done") -> ProactiveEvent {
        ProactiveEvent(kind: kind, title: title, outcome: outcome)
    }

    @Test
    func `All mode surfaces every kind`() async {
        let gate = OutcomeGate(mode: .all)
        for kind in ProactiveEventKind.allCases {
            let decision = await gate.decide(event: event(kind: kind))
            #expect(decision.surface == true)
        }
    }

    @Test
    func `Off mode suppresses every kind but keeps a headline`() async {
        let gate = OutcomeGate(mode: .off)
        for kind in ProactiveEventKind.allCases {
            let decision = await gate.decide(event: event(kind: kind, outcome: "Digest completed"))
            #expect(decision.surface == false)
            // Suppression hides the interruption only; the headline stays
            // populated so the run row and dashboard history still log it.
            #expect(!decision.headline.isEmpty)
        }
    }

    @Test
    func `Milestones mode surfaces milestones errors and parked only`() async {
        let gate = OutcomeGate(mode: .milestones)
        let surfaced: [ProactiveEventKind] = [.schedulerError, .goalAchieved, .goalNeedsInput, .goalBlocked, .runParked]
        let quiet: [ProactiveEventKind] = [.schedulerOk, .goalStepDone, .ideaProposed]
        for kind in surfaced {
            let decision = await gate.decide(event: event(kind: kind))
            #expect(decision.surface == true)
        }
        for kind in quiet {
            let decision = await gate.decide(event: event(kind: kind))
            #expect(decision.surface == false)
        }
    }

    @Test
    func `Guarded without judge degrades to milestones`() async {
        let gate = OutcomeGate(mode: .guarded)
        let routine = await gate.decide(event: event(kind: .schedulerOk))
        #expect(routine.surface == false)
        let milestone = await gate.decide(event: event(kind: .goalAchieved))
        #expect(milestone.surface == true)
        let parked = await gate.decide(event: event(kind: .runParked))
        #expect(parked.surface == true)
        let step = await gate.decide(event: event(kind: .goalStepDone))
        #expect(step.surface == false)
    }

    @Test
    func `Idea nudges surface only under all mode`() async {
        // A volunteered suggestion is not a milestone, so it follows the same suppression contract
        // as a routine step completion: surfaced by `all`, hidden by `off` and `milestones`, and
        // quiet under guarded without a dedicated judge branch.
        let all = await OutcomeGate(mode: .all).decide(event: event(kind: .ideaProposed, outcome: "Try a shorter loop"))
        #expect(all.surface == true)
        #expect(all.headline == "Try a shorter loop")
        let off = await OutcomeGate(mode: .off).decide(event: event(kind: .ideaProposed))
        #expect(off.surface == false)
        let milestones = await OutcomeGate(mode: .milestones).decide(event: event(kind: .ideaProposed))
        #expect(milestones.surface == false)
        let guarded = await OutcomeGate(mode: .guarded).decide(event: event(kind: .ideaProposed))
        #expect(guarded.surface == false)
    }

    @Test
    func `Guarded honors judge verdict for routine scheduler success`() async {
        let surfacing = OutcomeGate(
            mode: .guarded,
            judge: { _ in SurfacingVerdict(surface: true, headline: "Worth a look") }
        )
        let yes = await surfacing.decide(event: event(kind: .schedulerOk, outcome: "Routine digest"))
        #expect(yes.surface == true)
        #expect(yes.headline == "Worth a look")

        let quiet = OutcomeGate(
            mode: .guarded,
            judge: { _ in SurfacingVerdict(surface: false, headline: "Routine") }
        )
        let no = await quiet.decide(event: event(kind: .schedulerOk, outcome: "Routine digest"))
        #expect(no.surface == false)
        #expect(no.headline == "Routine")
    }

    @Test
    func `Guarded never judges milestones`() async {
        // A suppressing judge proves the milestone path never consults it: a
        // consulted judge would hide the milestone, while the correct path
        // surfaces with the deterministic headline.
        let gate = OutcomeGate(
            mode: .guarded,
            judge: { _ in SurfacingVerdict(surface: false, headline: "Should not run") }
        )
        let achieved = await gate.decide(event: event(kind: .goalAchieved, outcome: "Goal done"))
        #expect(achieved.surface == true)
        #expect(achieved.headline == "Goal done")
        let parked = await gate.decide(event: event(kind: .runParked, outcome: "Awaiting approval"))
        #expect(parked.surface == true)
        #expect(parked.headline == "Awaiting approval")
    }

    @Test
    func `Guarded never judges ideas or step completions`() async {
        // The guarded judge only weighs scheduler successes: a throwing judge proves the gate never
        // consults it for volunteered suggestions or routine step completions, because a consulted
        // judge would fail open to surfacing while the correct path stays suppressed.
        struct JudgeBoom: Error {}
        let gate = OutcomeGate(
            mode: .guarded,
            judge: { _ in throw JudgeBoom() }
        )
        let idea = await gate.decide(event: event(kind: .ideaProposed, outcome: "Try a shorter loop"))
        #expect(idea.surface == false)
        #expect(!idea.headline.isEmpty)
        let step = await gate.decide(event: event(kind: .goalStepDone, outcome: "Watered the basil"))
        #expect(step.surface == false)
        #expect(!step.headline.isEmpty)
    }

    @Test
    func `Throwing judge fails open to surfacing`() async {
        struct JudgeBoom: Error {}
        let gate = OutcomeGate(
            mode: .guarded,
            judge: { _ in throw JudgeBoom() }
        )
        let decision = await gate.decide(event: event(kind: .schedulerOk, outcome: "Routine digest"))
        #expect(decision.surface == true)
        #expect(!decision.headline.isEmpty)
    }

    @Test
    func `Judge headline clamps to ninety characters`() async {
        let long = String(repeating: "h", count: 200)
        let gate = OutcomeGate(
            mode: .guarded,
            judge: { _ in SurfacingVerdict(surface: true, headline: long) }
        )
        let decision = await gate.decide(event: event(kind: .schedulerOk, outcome: "Routine"))
        #expect(decision.headline.count == 90)
        #expect(decision.headline == String(long.prefix(90)))
    }

    @Test
    func `Default headline prefers preview and clamps to ninety`() async {
        let gate = OutcomeGate(mode: .all)
        let longOutcome = String(repeating: "x", count: 300)
        let decision = await gate.decide(event: event(kind: .schedulerOk, title: "Digest", outcome: longOutcome))
        // The 160-char preview feeds the 90-char headline, so a very long
        // outcome still lands within the badge budget.
        #expect(decision.headline.count <= 90)
        #expect(!decision.headline.isEmpty)

        let blankOutcome = await gate.decide(event: event(kind: .schedulerOk, title: "Digest title", outcome: "   "))
        #expect(blankOutcome.headline == "Digest title")
    }

    @Test
    func `Preview truncates to one sixty with shared ellipsis rule`() {
        let long = String(repeating: "a", count: 500)
        let preview = ProactiveEvent.makePreview(long)
        #expect(preview == String(long.prefix(160)) + "…")
        #expect(preview.count == 161)

        let short = ProactiveEvent.makePreview("  hello  ")
        #expect(short == "hello")

        let event = ProactiveEvent(kind: .schedulerOk, title: "T", outcome: long)
        #expect(event.preview == preview)
        #expect(ProactiveEvent.makePreview(long) == schedulerPreviewMirror(long))
    }

    @Test
    func `Proactive config defaults to surfacing everything`() {
        let config = ProactiveConfig()
        #expect(config.mode == .all)
        #expect(config.judgeTimeoutSeconds == 15)
        #expect(RuneWeaverConfig.default.proactive == ProactiveConfig())
    }

    @Test
    func `Absent proactive table decodes to defaults`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.proactive == ProactiveConfig())
        try config.validate()
    }

    @Test
    func `Explicit proactive section decodes and round-trips`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [proactive]
        mode = "guarded"
        judge_timeout_seconds = 20
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.proactive.mode == .guarded)
        #expect(config.proactive.judgeTimeoutSeconds == 20)
        try config.validate()

        var roundTrip = RuneWeaverConfig.default
        roundTrip.proactive = config.proactive
        let rendered = roundTrip.renderTOML()
        #expect(rendered.contains("[proactive]"))
        #expect(rendered.contains("mode = \"guarded\""))
        #expect(rendered.contains("judge_timeout_seconds = 20"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.proactive == config.proactive)
        try reparsed.validate()
    }

    @Test
    func `Proactive validation bounds judge timeout`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [proactive]
        mode = "all"
        judge_timeout_seconds = 0
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(throws: ConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func `Proactive decoder rejects unknown mode`() {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [proactive]
        mode = "sometimes"
        """
        #expect(throws: ConfigError.self) {
            _ = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        }
    }

    @Test
    func `Guarded slow judge times out and fails open`() async {
        // A judge slower than the bounded budget must not swallow the outcome:
        // the timeout path surfaces with the deterministic fallback headline.
        let gate = OutcomeGate(
            mode: .guarded,
            judgeTimeoutSeconds: 1,
            judge: { _ in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return SurfacingVerdict(surface: false, headline: "Too late")
            }
        )
        let decision = await gate.decide(event: event(kind: .schedulerOk, outcome: "Routine digest"))
        #expect(decision.surface == true)
        #expect(!decision.headline.isEmpty)
    }

    @Test
    func `Proactive file loader accepts case-insensitive mode`() throws {
        // The TOML decoder trims and lowercases before matching, so the same
        // spellings the dashboard normalizes to must load from disk.
        let variants: [(raw: String, expected: ProactiveMode)] = [
            ("ALL", .all),
            ("  Guarded  ", .guarded),
            ("MILESTONES", .milestones),
            ("Off", .off)
        ]
        for variant in variants {
            let text = """
            [llm]
            default_provider = "mlx"

            [llm.providers.mlx]
            enabled = true
            model = "gemma-4-9b"
            server_url = "http://localhost:8080"

            [proactive]
            mode = "\(variant.raw)"
            """
            let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
            #expect(config.proactive.mode == variant.expected)
            try config.validate()
        }
    }

    @Test
    func `Proactive message frame tolerantly decodes goal aliases`() throws {
        // The frame encodes the goal link under canonical `goalId`; the
        // decoder still accepts the historical `goalID` and `goal_id`
        // spellings so older payloads keep linking.
        let goalID = UUID()
        let frame = WSProactiveMessageFrame(
            kind: "goalStepDone",
            title: "Tend herbs",
            headline: "Watered the basil.",
            goalID: goalID
        )
        let data = try JSONEncoder().encode(frame)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"goalId\""))
        #expect(!text.contains("\"goalID\""))
        #expect(!text.contains("\"goal_id\""))

        for alias in ["goalId", "goalID"] {
            let aliased = text.replacingOccurrences(of: "\"goalId\"", with: "\"\(alias)\"")
            let decoded = try JSONDecoder().decode(WSProactiveMessageFrame.self, from: Data(aliased.utf8))
            #expect(decoded.goalID == goalID)
            #expect(decoded == frame)
        }

        // When several spellings ride together the canonical key wins, keeping
        // the link deterministic instead of last-write-wins.
        let canonicalID = UUID()
        let legacyID = UUID()
        let canonicalFrame = WSProactiveMessageFrame(
            kind: "goalStepDone",
            title: "Tend herbs",
            headline: "Watered the basil.",
            goalID: canonicalID
        )
        let canonicalData = try JSONEncoder().encode(canonicalFrame)
        var dict = try #require(try JSONSerialization.jsonObject(with: canonicalData) as? [String: Any])
        dict["goalID"] = legacyID.uuidString
        let merged = try JSONSerialization.data(withJSONObject: dict)
        let mergedDecoded = try JSONDecoder().decode(WSProactiveMessageFrame.self, from: merged)
        #expect(mergedDecoded.goalID == canonicalID)
    }

    @Test
    func `Interruption frame encodes kind title and headline`() throws {
        // The shared wire shape carries kind, title, and headline so the
        // dashboard can badge even with no macOS notifier; session and goal
        // links ride along for deep-linking without a second lookup.
        let frame = WSProactiveMessageFrame(kind: ProactiveEventKind.schedulerOk.rawValue, title: "Morning digest", headline: "Worth a look")
        #expect(frame.type == "proactive_message")
        let data = try JSONEncoder().encode(frame)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("proactive_message"))
        #expect(text.contains("schedulerOk"))
        #expect(text.contains("Morning digest"))
        #expect(text.contains("Worth a look"))
        let decoded = try JSONDecoder().decode(WSProactiveMessageFrame.self, from: data)
        #expect(decoded == frame)
    }
}

/// Mirrors the notify short-text truncation so the preview test pins the
/// shared rule instead of a copy that could drift.
private func schedulerPreviewMirror(_ text: String) -> String {
    let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return preview.count > 160 ? String(preview.prefix(160)) + "…" : preview
}
