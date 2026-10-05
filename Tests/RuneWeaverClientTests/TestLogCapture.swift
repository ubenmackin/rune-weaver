// Rune Weaver Client Tests — Test-only swift-log capture bootstrap.
//
// This target's suites talk to stub transports whose core-engine paths emit
// intentional warning- and error-level fail-soft events through the
// centralized RuneWeaverLog loggers. Left
// unrouted, the swift-log default handler mirrors those events to the
// console, which breaks the contract that a captured test run contains zero
// warning/error lines. This file installs a test-only handler that records
// every event in memory instead of printing it, so behavioral assertions can
// consult the captured store while the console stays silent. Installation
// runs from a Swift Testing trait's preparation step, which the library
// invokes after discovering all tests and their traits and before it begins
// to run any of them: strictly earlier than the first touch of any lazy
// Logger static initializer, because those are only reached from test bodies.
// One process hosts exactly one test bundle here, so the one-shot global
// bootstrap is claimed once by whichever installation lands first.

import Foundation
import Logging
import os
import Testing

/// Pins the unqualified name `Logger` to the swift-log type. This file must
/// import `os` for `OSAllocatedUnfairLock`, and that module exports its own
/// `Logger`, so without this binding every `Logger` spelling below would be
/// ambiguous between the two imports. Aliasing once keeps the handler
/// conformance and the Record API in their natural spelling instead of
/// forcing `Logging.` qualifications at every use site; no other file in the
/// test targets references `Logger`, so the binding cannot steer a sibling
/// file's name lookup.
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

    /// Lock-protected record list shared by every handler instance.
    ///
    /// swift-log requires handlers to be value types, so the process-wide
    /// store must live behind a reference that handler copies share.
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

    /// Claim-or-skip latch for the one-shot bootstrap. swift-log traps when
    /// `bootstrap` runs twice in one process, so the first `install()` claims
    /// the latch and every later call collapses to a no-op. The bootstrap
    /// happens under the latch so a losing call can never observe "claimed"
    /// before the winning call has finished installing the factory.
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
///
/// `prepare(for:)` is the earliest public hook the testing library offers:
/// it is invoked after all tests and their traits are discovered and before
/// any test body runs, which is the window in which a global bootstrap is
/// still guaranteed to precede every lazy Logger creation in this process.
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
