// Rune Weaver Tests — Fan-out run lifecycle broadcasts through the hub adapter.

import Foundation
import NIOWebSocket
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

/// Decoded `run_started` / `run_completed` envelope plus its nested run row.
private struct RecordedRunFrame: Decodable {
    /// Frame discriminator: `run_started` or `run_completed`.
    let type: String
    /// Row carried by the frame.
    let run: RunLogEntry
}

/// Recording socket capturing lifecycle frames without a live handshake,
/// mirroring the broadcast delivery fixtures.
private actor FanOutFrameSocket: WSConnectionSocket {
    /// Raw frames delivered to this connection, in send order.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}

    /// Decodes the recorded frames. A malformed payload is dropped rather than thrown so a count
    /// assertion names the missing frame instead of failing the whole read.
    func decodedFrames() -> [RecordedRunFrame] {
        sent.compactMap { raw in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RecordedRunFrame.self, from: data)
        }
    }
}

/// Immediate worker seam producing deterministic output so a swarm settles
/// without an LLM stack; the engine's worker loop stays with the core suite.
private struct RecordingFanOutSeam: OrchestratorFanOutSeam, Sendable {
    /// Runs one worker turn, discarding its output.
    func process(_ input: UserInput) async throws {
        _ = try await processCollecting(input)
    }

    /// Produces deterministic output tagged with the worker's own prompt.
    func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput {
        FanOutWorkerOutput(text: "Output for \(input.text)", isParked: false)
    }
}

/// Polls until the socket recorded at least `expected` frames or the budget expires, so the test
/// orders itself against live broadcasts instead of racing fixed sleeps. expected:
/// Frame count to wait for.
private func waitForFanOutFrames(
    _ expected: Int,
    on socket: FanOutFrameSocket,
    timeoutSeconds: Double = 5
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await socket.sent.count >= expected {
            return true
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return await socket.sent.count >= expected
}

@Suite("Fan-Out Run Broadcast Adapter")
struct FanOutRunBroadcastAdapterTests {
    @Test
    func `Append broadcasts one run_started frame with the row identity`() async throws {
        let hub = WSHub()
        let socket = FanOutFrameSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let adapter = FanOutRunLogAdapter(runs: RunLogStore(), hub: hub)
        let sessionID = UUID()
        let rowID = await adapter.appendFanOutRow(
            kind: FanOutEngine.workerRowKind,
            status: "running",
            message: "Worker Alpha",
            sessionID: sessionID
        )
        let frames = await socket.decodedFrames()
        try #require(frames.count == 1)
        let frame = frames[0]
        #expect(frame.type == "run_started")
        #expect(frame.run.id == rowID)
        #expect(frame.run.sessionID == sessionID)
        #expect(frame.run.kind == FanOutEngine.workerRowKind)
        #expect(frame.run.status == "running")
    }

    @Test
    func `Settle broadcasts run_completed for both update witnesses`() async throws {
        let hub = WSHub()
        let socket = FanOutFrameSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let adapter = FanOutRunLogAdapter(runs: RunLogStore(), hub: hub)
        let sessionID = UUID()
        // Response-carrying witness: a worker's raw output and duration must
        // reach the frame, not just the flipped badge.
        let workerRowID = await adapter.appendFanOutRow(
            kind: FanOutEngine.workerRowKind,
            status: "running",
            message: "Worker Alpha",
            sessionID: sessionID
        )
        await adapter.updateFanOutRow(id: workerRowID, status: "ok", response: "raw worker output", durationMs: 42)
        // Status-only witness: callers that only flip a badge still broadcast.
        let parentRowID = await adapter.appendFanOutRow(
            kind: FanOutEngine.parentRowKind,
            status: "running",
            message: "Alpha; Beta",
            sessionID: sessionID
        )
        await adapter.updateFanOutRow(id: parentRowID, status: "cancelled")
        let frames = await socket.decodedFrames()
        try #require(frames.count == 4)
        #expect(frames[0].type == "run_started")
        #expect(frames[1].type == "run_completed")
        #expect(frames[1].run.id == workerRowID)
        #expect(frames[1].run.sessionID == sessionID)
        #expect(frames[1].run.status == "ok")
        #expect(frames[1].run.response == "raw worker output")
        #expect(frames[1].run.durationMs == 42)
        #expect(frames[2].type == "run_started")
        #expect(frames[3].type == "run_completed")
        #expect(frames[3].run.id == parentRowID)
        #expect(frames[3].run.status == "cancelled")
    }

    @Test
    func `Unknown row update broadcasts nothing`() async {
        let hub = WSHub()
        let socket = FanOutFrameSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let adapter = FanOutRunLogAdapter(runs: RunLogStore(), hub: hub)
        await adapter.updateFanOutRow(id: UUID(), status: "ok")
        await adapter.updateFanOutRow(id: UUID(), status: "error", response: "lost", durationMs: 7)
        let frames = await socket.decodedFrames()
        // A settle racing a pruned or foreign row must not fabricate a frame
        // no viewer can reconcile against a stored row.
        #expect(frames.isEmpty)
    }
}

@Suite("Fan-Out Swarm Broadcast")
struct FanOutSwarmBroadcastTests {
    @Test
    func `Two-subtask swarm broadcasts parent and worker lifecycle frames`() async throws {
        let hub = WSHub()
        let socket = FanOutFrameSocket()
        let secondSocket = FanOutFrameSocket()
        _ = await hub.add(id: UUID(), box: socket)
        _ = await hub.add(id: UUID(), box: secondSocket)
        let engine = FanOutEngine(
            orchestrator: RecordingFanOutSeam(),
            runLogs: FanOutRunLogAdapter(runs: RunLogStore(), hub: hub),
            config: FanOutConfig()
        )
        let originSessionID = UUID()
        let run = try await engine.runFanOut(
            subtasks: [
                FanOutSubtask(title: "Alpha", prompt: "Prompt for Alpha"),
                FanOutSubtask(title: "Beta", prompt: "Prompt for Beta")
            ],
            originSessionID: originSessionID
        )
        #expect(run.status == .completed)
        #expect(run.parentSessionID == originSessionID)
        let arrived = await waitForFanOutFrames(6, on: socket)
        let secondArrived = await waitForFanOutFrames(6, on: secondSocket)
        #expect(arrived == true)
        #expect(secondArrived == true)
        let rawFrames = await socket.sent
        let frames = await socket.decodedFrames()
        // Both counts agree only when every raw frame decoded as the
        // `{"type","run"}` envelope, which is the consumer contract.
        #expect(rawFrames.count == 6)
        #expect(frames.count == 6)
        // A second connected viewer needs no extra wiring: the whole swarm
        // lifecycle reaches it (and every other socket) without a re-send.
        let secondFrames = await secondSocket.decodedFrames()
        #expect(secondFrames.count == 6)
        #expect(secondFrames.filter { $0.type == "run_started" }.count == 3)
        #expect(secondFrames.filter { $0.type == "run_completed" }.count == 3)

        let startedFrames = frames.filter { $0.type == "run_started" }
        let completedFrames = frames.filter { $0.type == "run_completed" }
        #expect(startedFrames.count == 3)
        #expect(completedFrames.count == 3)

        // The parent row keeps the caller's session on both lifecycle frames.
        let startedParent = try #require(startedFrames.first { $0.run.kind == FanOutEngine.parentRowKind })
        #expect(startedParent.run.sessionID == originSessionID)
        #expect(startedParent.run.status == "running")
        let completedParent = try #require(completedFrames.first { $0.run.kind == FanOutEngine.parentRowKind })
        #expect(completedParent.run.id == startedParent.run.id)
        #expect(completedParent.run.sessionID == originSessionID)
        #expect(completedParent.run.status == "ok")
        #expect(completedParent.run.response?.isEmpty == false)

        // Each worker row carries its own fresh session, and every completion
        // pairs with the started frame that shares its row id.
        let startedWorkers = startedFrames.filter { $0.run.kind == FanOutEngine.workerRowKind }
        let completedWorkers = completedFrames.filter { $0.run.kind == FanOutEngine.workerRowKind }
        try #require(startedWorkers.count == 2)
        try #require(completedWorkers.count == 2)
        let workerSessions = Set(startedWorkers.compactMap(\.run.sessionID))
        #expect(workerSessions.count == 2)
        #expect(workerSessions.contains(originSessionID) == false)
        for frame in completedWorkers {
            #expect(frame.run.status == "ok")
            #expect(startedWorkers.contains { $0.run.id == frame.run.id })
            let frameSession = try #require(frame.run.sessionID)
            #expect(workerSessions.contains(frameSession))
        }
    }
}
