// Rune Weaver Tests — Untrusted tool-progress wire decode and field sanitizers.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Complete baseline fields for a well-formed frame; callers override one field
/// to isolate the behavior under test.
/// - Returns: Wire field values keyed by wire name.
private func baseProgressFields() -> [String: Any] {
    [
        "type": "tool_progress",
        "callID": "call_1",
        "toolName": "files.grep",
        "message": "Scanning",
        "scanned": 7,
        "matched": 3,
        "elapsedMs": 12
    ]
}

/// Encodes an arbitrary progress payload so individual fields can be omitted, fractionalized, or
/// made unsafe without hand-building JSON braces. - Parameter fields: Field values keyed by wire
/// name.
private func progressPayload(_ fields: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: fields)
}

/// Decodes one generated payload, surfacing the decoder's error. - Parameter data: UTF-8 JSON data.
private func decodeProgressFrame(_ data: Data) throws -> WSToolProgressFrame {
    try JSONDecoder().decode(WSToolProgressFrame.self, from: data)
}

/// Decodes one generated payload the way a live consumer does: any failure drops the frame rather
/// than surfacing an error. - Parameter fields: Field values keyed by wire name.
private func decodedProgress(_ fields: [String: Any]) -> WSToolProgressFrame? {
    guard let data = try? progressPayload(fields) else { return nil }
    return try? decodeProgressFrame(data)
}

/// Decodes one raw text payload the way a live consumer does.
/// - Parameter raw: Raw frame text.
/// - Returns: The decoded frame, or nil when the payload is rejected.
private func decodedProgressRaw(_ raw: String) -> WSToolProgressFrame? {
    try? decodeProgressFrame(Data(raw.utf8))
}

@Suite("Tool Progress Wire")
struct ToolProgressWireTests {
    @Test
    func `Valid progress frames decode and expose every field`() throws {
        let sessionID = UUID()
        var fields = baseProgressFields()
        fields["sessionID"] = sessionID.uuidString
        fields["warning"] = "  Broad scope  "
        fields["current"] = "  notes/one.txt  "

        let frame = try decodeProgressFrame(progressPayload(fields))

        #expect(frame.type == "tool_progress")
        #expect(frame.sessionID == sessionID)
        #expect(frame.callID == "call_1")
        #expect(frame.toolName == "files.grep")
        #expect(frame.message == "Scanning")
        #expect(frame.warning == "Broad scope")
        #expect(frame.scanned == 7)
        #expect(frame.matched == 3)
        #expect(frame.elapsedMs == 12)
        // Display copy is trimmed but the relative shape survives untouched.
        #expect(frame.current == "notes/one.txt")
    }

    @Test
    func `A missing discriminator still decodes for back-compat`() throws {
        var fields = baseProgressFields()
        fields.removeValue(forKey: "type")
        let frame = try decodeProgressFrame(progressPayload(fields))
        #expect(frame.type == "tool_progress")
    }

    @Test
    func `Absolute home and traversing display paths degrade to nil on decode`() throws {
        for candidate in ["/etc/passwd", "~/secrets", "../escape", "a/../../b", ".."] {
            var fields = baseProgressFields()
            fields["current"] = candidate
            let frame = try decodeProgressFrame(progressPayload(fields))
            #expect(frame.current == nil, "\(candidate) must not survive as a display path")
        }
    }

    @Test
    func `Relative display paths survive and cap at the display bound`() throws {
        var relative = baseProgressFields()
        relative["current"] = "notes/deep/one.txt"
        let frame = try decodeProgressFrame(progressPayload(relative))
        #expect(frame.current == "notes/deep/one.txt")

        var oversized = baseProgressFields()
        oversized["current"] = String(repeating: "a", count: ToolProgress.maxCurrentLength + 25)
        let capped = try decodeProgressFrame(progressPayload(oversized))
        #expect(capped.current?.count == ToolProgress.maxCurrentLength)
    }

    @Test
    func `Blank or missing warnings collapse to absent on decode`() throws {
        for candidate in ["", "   ", "\n\t "] {
            var fields = baseProgressFields()
            fields["warning"] = candidate
            let frame = try decodeProgressFrame(progressPayload(fields))
            #expect(frame.warning == nil, "Whitespace-only warning must not render")
        }
        let absent = try decodeProgressFrame(progressPayload(baseProgressFields()))
        #expect(absent.warning == nil)
        #expect(absent.current == nil)
    }

    @Test
    func `A drifted non-string warning degrades to absent without dropping the frame`() {
        // A handcrafted peer can send any JSON shape for the optional warning. The
        // dashboard degrades a non-string warning to absent and keeps the line, so
        // the wire decoder must not let a malformed optional cost the whole frame.
        let candidates: [Any] = [7, 1.5, true, ["scope"], ["level": "broad"]]
        for candidate in candidates {
            var fields = baseProgressFields()
            fields["warning"] = candidate
            let frame = decodedProgress(fields)
            #expect(frame != nil, "A drifted warning must keep the frame")
            #expect(frame?.warning == nil, "A non-string warning must degrade to absent")
        }
    }

    @Test
    func `A drifted non-string current degrades to absent without dropping the frame`() {
        // The dashboard's relativeProgressCurrent treats every non-string `current`
        // as absent and keeps the progress line, so the decoder must match: an
        // optional display tail is never worth dropping an otherwise complete frame.
        let candidates: [Any] = [7, 1.5, true, ["notes"], ["path": "notes/one.txt"]]
        for candidate in candidates {
            var fields = baseProgressFields()
            fields["current"] = candidate
            let frame = decodedProgress(fields)
            #expect(frame != nil, "A drifted current must keep the frame")
            #expect(frame?.current == nil, "A non-string current must degrade to absent")
        }
    }

    @Test
    func `Blank identity drops the frame while padded identity survives`() {
        // The dashboard guard rejects a whitespace-only callID or toolName but
        // keeps the raw value when real identity is merely padded, so the engine
        // must fail on exactly the same boundary to hold the parity contract.
        for key in ["callID", "toolName"] {
            for blank in ["", "   ", "\n\t "] {
                var fields = baseProgressFields()
                fields[key] = blank
                #expect(decodedProgress(fields) == nil, "Blank \(key) must drop the frame")
            }
        }
        var padded = baseProgressFields()
        padded["callID"] = "  call_1  "
        padded["toolName"] = "  files.grep  "
        let frame = decodedProgress(padded)
        #expect(frame?.callID == "  call_1  ")
        #expect(frame?.toolName == "  files.grep  ")
    }

    @Test
    func `Negative counters are rejected rather than zeroed on the wire`() {
        for key in ["scanned", "matched", "elapsedMs"] {
            var fields = baseProgressFields()
            fields[key] = -1
            #expect(decodedProgress(fields) == nil, "\(key) below zero must drop the frame")
        }
    }

    @Test
    func `Fractional and non-integer counters are rejected on the wire`() {
        var fractional = baseProgressFields()
        fractional["scanned"] = 1.5
        #expect(decodedProgress(fractional) == nil)

        var stringy = baseProgressFields()
        stringy["matched"] = "3"
        #expect(decodedProgress(stringy) == nil)

        var boolean = baseProgressFields()
        boolean["elapsedMs"] = true
        #expect(decodedProgress(boolean) == nil)
    }

    @Test
    func `Missing counters and identity fields drop the frame`() {
        for key in ["callID", "toolName", "message", "scanned", "matched", "elapsedMs"] {
            var fields = baseProgressFields()
            fields.removeValue(forKey: key)
            #expect(decodedProgress(fields) == nil, "Missing \(key) must drop the frame")
        }
    }

    @Test
    func `Malformed and truncated payloads drop instead of decoding`() {
        let malformed = [
            "not json",
            "{\"type\":\"tool_progress\"}",
            "{\"type\":\"tool_progress\",\"callID\":\"c\""
        ]
        for raw in malformed {
            #expect(decodedProgressRaw(raw) == nil, "Malformed payload \(raw) must be dropped")
        }
    }

    @Test
    func `Normalized warning trims content and drops blank copy`() {
        #expect(ToolProgress.normalizedWarning(nil) == nil)
        #expect(ToolProgress.normalizedWarning("") == nil)
        #expect(ToolProgress.normalizedWarning("   \n\t ") == nil)
        #expect(ToolProgress.normalizedWarning("  scope note  ") == "scope note")
    }

    @Test
    func `Relative current drops absolute home and traversal candidates`() {
        for candidate in ["/etc/passwd", "~/secrets", "../escape", "a/../../b", "..", ""] {
            #expect(ToolProgress.relativeCurrent(candidate) == nil, "\(candidate) must not survive")
        }
        #expect(ToolProgress.relativeCurrent(nil) == nil)
        #expect(ToolProgress.relativeCurrent("  notes/one.txt  ") == "notes/one.txt")
        #expect(ToolProgress.relativeCurrent("./notes/one.txt") == "./notes/one.txt")
        let capped = ToolProgress.relativeCurrent(String(repeating: "a", count: 300))
        #expect(capped?.count == ToolProgress.maxCurrentLength)
    }

    @Test
    func `Emitter constructors clamp counters and drop unsafe display fields`() {
        // Constructors clamp rather than reject: an emitter bug should cost the
        // viewer one honest field, not the whole progress line the decoder would
        // otherwise drop over a single bad value.
        let progress = ToolProgress(
            message: "Scanning",
            warning: "   ",
            scanned: -5,
            matched: -2,
            elapsedMs: -1,
            current: "/etc/passwd"
        )
        #expect(progress.scanned == 0)
        #expect(progress.matched == 0)
        #expect(progress.elapsedMs == 0)
        #expect(progress.warning == nil)
        #expect(progress.current == nil)

        let frame = WSToolProgressFrame(
            sessionID: nil,
            callID: "call_1",
            toolName: "files.grep",
            message: "Scanning",
            warning: "  ",
            scanned: -1,
            matched: -1,
            elapsedMs: -1,
            current: "../escape"
        )
        #expect(frame.scanned == 0)
        #expect(frame.matched == 0)
        #expect(frame.elapsedMs == 0)
        #expect(frame.warning == nil)
        #expect(frame.current == nil)
    }
}
