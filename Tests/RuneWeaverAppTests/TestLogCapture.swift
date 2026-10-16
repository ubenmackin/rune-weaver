// Rune Weaver App Tests — Test-only swift-log capture bootstrap.

import Foundation
import Logging
import os
import Testing

/// Pins the unqualified name `Logger` to the swift-log type.
typealias Logger = Logging.Logger

/// In-memory capture store plus the one-shot global logging bootstrap.
enum TestLogCapture {
    /// One captured log event.
    struct Record: Sendable {
        /// Logger label the event was emitted through.
        let label: String
        /// Severity of the event.
        let level: Logger.Level
        /// Rendered message text.
        let message: String
        /// Module or explicit source that emitted the event.
        let source: String
    }

    /// Lock-protected record list shared by every handler instance. swift-log requires handlers to
    /// be value types, so the process-wide store must live behind a reference that handler copies
    /// share.
    private final class Sink: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [Record]())

        func append(_ record: Record) {
            self.state.withLock { $0.append(record) }
        }

        var snapshot: [Record] {
            self.state.withLock { $0 }
        }
    }

    private static let sink = Sink()

    /// Claim-or-skip latch for the one-shot bootstrap. swift-log traps when `bootstrap` runs twice
    /// in one process, so the first `install()` claims the latch and every later call collapses to a
    /// no-op.
    private static let installGuard = OSAllocatedUnfairLock(initialState: false)

    /// Installs the capture handler as the process-wide log factory.
    static func install() {
        self.installGuard.withLock { installed in
            guard !installed else { return }
            installed = true
            LoggingSystem.bootstrap { label in
                CaptureHandler(label: label, sink: TestLogCapture.sink)
            }
        }
    }

    /// Captured records at `level` (warning by default) whose message
    /// contains `fragment`, in emission order.
    static func records(level: Logger.Level = .warning, containing fragment: String) -> [Record] {
        self.sink.snapshot.filter { $0.level == level && $0.message.contains(fragment) }
    }

    /// Every record captured so far.
    static var allRecords: [Record] {
        self.sink.snapshot
    }

    /// Log handler that appends to the shared sink and writes nothing to the
    /// console. Deliberately silent at every level: routing must be uniform,
    /// or the very fail-soft noise this exists to contain leaks back out.
    private struct CaptureHandler: LogHandler {
        let label: String
        let sink: Sink
        var metadataProvider: Logger.MetadataProvider?
        var logLevel: Logger.Level = .info

        private var metadataStore: Logger.Metadata = [:]

        var metadata: Logger.Metadata {
            get { self.metadataStore }
            set { self.metadataStore = newValue }
        }

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { self.metadataStore[key] }
            set { self.metadataStore[key] = newValue }
        }

        func log(event: LogEvent) {
            self.sink.append(
                Record(
                    label: self.label,
                    level: event.level,
                    message: event.message.description,
                    source: event.source
                )
            )
        }
    }
}

/// Suite trait that performs the capture installation during preparation.
struct TestLogCaptureBootstrap: SuiteTrait {
    func prepare(for _: Test) async throws {
        TestLogCapture.install()
    }

    var comments: [Comment] {
        ["Installs the in-memory swift-log capture before the first test body runs."]
    }
}

extension Trait where Self == TestLogCaptureBootstrap {
    /// Fluent spelling for the bootstrap trait.
    static var testLogCaptureBootstrap: Self {
        TestLogCaptureBootstrap()
    }
}

@Suite("Test log capture bootstrap", .testLogCaptureBootstrap)
struct TestLogCaptureBootstrapTests {
    @Test
    func `Installation is idempotent and captures warnings instead of printing them`() {
        // A repeated call must collapse onto the single first bootstrap; a
        // real second LoggingSystem.bootstrap would trap the test process.
        TestLogCapture.install()

        let probeLabel = "com.runeweaver.test.log-capture-probe"
        Logger(label: probeLabel).warning("capture probe")
        #expect(TestLogCapture.records(containing: "capture probe").contains { $0.label == probeLabel })
    }
}
