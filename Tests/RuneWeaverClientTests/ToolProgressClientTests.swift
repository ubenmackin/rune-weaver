// Rune Weaver Tests — Client-side tool-progress frame handling.
//
// The client's streaming loop decodes every `tool_progress` frame through the
// `ClientToolProgressFrame` alias (single-sourced from the engine's
// `WSToolProgressFrame`) and then drops it: indeterminate progress is advisory
// and has no place in the content stream `RuneWeaverClient.send` exposes. The
// decode is still load-bearing, because the branch uses `try?` so a malformed or
// drifted payload is validated locally and swallowed rather than surfacing. The
// private frame dispatcher cannot be driven without a live socket, so these
// tests pin the alias contract it depends on at that reachable seam.

import Foundation
@testable import RuneWeaverClient
import Testing

/// Decodes one raw frame through the same alias the client's `tool_progress`
/// branch consumes, using `try?` exactly as the branch does.
/// - Parameter raw: Raw frame text.
/// - Returns: The decoded frame, or nil when the branch would drop it.
private func decodedClientProgress(_ raw: String) -> ClientToolProgressFrame? {
    try? JSONDecoder().decode(ClientToolProgressFrame.self, from: Data(raw.utf8))
}

@Suite("Client Tool Progress")
struct ToolProgressClientTests {
    @Test
    func `Full frames decode and sanitize untrusted display fields`() throws {
        let raw = """
        {"type":"tool_progress","callID":"call_1","toolName":"files.grep","message":"Scanning",\
        "warning":"   ","scanned":7,"matched":3,"elapsedMs":12,"current":"/etc/passwd"}
        """
        let frame = try #require(decodedClientProgress(raw))
        #expect(frame.callID == "call_1")
        #expect(frame.toolName == "files.grep")
        #expect(frame.message == "Scanning")
        #expect(frame.scanned == 7)
        #expect(frame.matched == 3)
        #expect(frame.elapsedMs == 12)
        // A hand-crafted frame cannot smuggle an absolute path or an empty
        // warning into the client's view state.
        #expect(frame.warning == nil)
        #expect(frame.current == nil)
    }

    @Test
    func `Malformed and drifted payloads drop before surfacing`() {
        let rejected = [
            "not json",
            #"{"type":"tool_progress"}"#,
            #"{"type":"tool_progress","callID":"c","toolName":"t","message":"m","scanned":-1,"matched":0,"elapsedMs":0}"#,
            #"{"type":"tool_progress","callID":"c","toolName":"t","message":"m","scanned":1.5,"matched":0,"elapsedMs":0}"#,
            #"{"type":"tool_progress","callID":"c","toolName":"t","message":"m","scanned":0,"matched":0"#
        ]
        for raw in rejected {
            #expect(decodedClientProgress(raw) == nil, "\(raw) must be dropped by the client branch")
        }
    }
}
