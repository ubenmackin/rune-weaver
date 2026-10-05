// Rune Weaver App Tests — Menu-bar label state priority truth tables.
//
// Purpose: Pins the single-selector priority for the menu-bar indicator so a
// cold boot reads as progress, a token-adopt restart names the in-flight hop,
// and a parked approval is never hidden behind desktop or indexing liveness.
// Scope: Direct calls to the pure AppMenuLabel.labelState helper only. No view
// rendering, no model boot, and no embedded service, so the suite stays fast
// and hermetic while covering every priority pair.
// Architectural role: Guards the bar-versus-dropdown contract where failure
// shows a distinct mark in the bar while the dropdown carries the actionable
// copy, and where boot progress outranks activity so the bar never reads as
// idle while the running flag is still down.

@testable import RuneWeaverApp
import Testing

@Suite("Menu label state")
struct MenuLabelStateTests {
    @Test
    func `failed beats cold-start progress`() {
        // A refused bind during boot must read as failure in the bar, never as
        // healthy idle or as the starting wait; the dropdown owns the
        // actionable copy, so failure wins over the starting wait.
        #expect(AppMenuLabel.labelState(
            isRunning: false,
            isServerFailed: true,
            isRestarting: false,
            hasApprovals: false,
            isDesktopActive: false,
            isIndexing: false
        ) == .failed)
    }

    @Test
    func `failed beats approvals plus restart plus activity`() {
        // Failure is the top selector, so even a fully lit board with a parked
        // write, an in-flight restart, and live activity still reads failed.
        #expect(AppMenuLabel.labelState(
            isRunning: true,
            isServerFailed: true,
            isRestarting: true,
            hasApprovals: true,
            isDesktopActive: true,
            isIndexing: true
        ) == .failed)
    }

    @Test
    func `approvals beats cold-start progress`() {
        // A parked write outranks the boot wait so approval never hides behind
        // a spinner while the service is still coming up.
        #expect(AppMenuLabel.labelState(
            isRunning: false,
            isServerFailed: false,
            isRestarting: false,
            hasApprovals: true,
            isDesktopActive: false,
            isIndexing: false
        ) == .approvals)
    }

    @Test
    func `approvals beats restart plus desktop plus indexing`() {
        // A parked write outranks every progress and activity indicator, so
        // the count stays visible while a restart hop or a batch runs.
        #expect(AppMenuLabel.labelState(
            isRunning: true,
            isServerFailed: false,
            isRestarting: true,
            hasApprovals: true,
            isDesktopActive: true,
            isIndexing: true
        ) == .approvals)
    }

    @Test
    func `restarting wins while stopped`() {
        // A token-adopt restart can hold the running flag down across the hop,
        // so the restart names the wait even before the new bind goes live.
        #expect(AppMenuLabel.labelState(
            isRunning: false,
            isServerFailed: false,
            isRestarting: true,
            hasApprovals: false,
            isDesktopActive: false,
            isIndexing: false
        ) == .restarting)
    }

    @Test
    func `restarting wins while running`() {
        // The same hop can also overlap a still-live flag, so restarting must
        // win regardless of which side of the shutdown the snapshot lands on.
        #expect(AppMenuLabel.labelState(
            isRunning: true,
            isServerFailed: false,
            isRestarting: true,
            hasApprovals: false,
            isDesktopActive: false,
            isIndexing: false
        ) == .restarting)
    }

    @Test
    func `restarting beats desktop plus indexing`() {
        // The restart hop outranks live activity so the bar never swaps the
        // restart wait for an activity mark mid-adopt.
        #expect(AppMenuLabel.labelState(
            isRunning: true,
            isServerFailed: false,
            isRestarting: true,
            hasApprovals: false,
            isDesktopActive: true,
            isIndexing: true
        ) == .restarting)
    }

    @Test
    func `starting beats desktop activity`() {
        // Cold boot holds the running flag down, so the wait must win over a
        // stale or early activity flag instead of reading as live control.
        #expect(AppMenuLabel.labelState(
            isRunning: false,
            isServerFailed: false,
            isRestarting: false,
            hasApprovals: false,
            isDesktopActive: true,
            isIndexing: false
        ) == .starting)
    }

    @Test
    func `starting beats indexing activity`() {
        // Same cold-boot invariant for the index mark: progress wins over a
        // run snapshot so the bar never reads as syncing before it is live.
        #expect(AppMenuLabel.labelState(
            isRunning: false,
            isServerFailed: false,
            isRestarting: false,
            hasApprovals: false,
            isDesktopActive: false,
            isIndexing: true
        ) == .starting)
    }

    @Test
    func `starting is the cold-launch baseline`() {
        // No flags besides a down running flag is the plain cold launch, which
        // must read as progress rather than falling through to idle.
        #expect(AppMenuLabel.labelState(
            isRunning: false,
            isServerFailed: false,
            isRestarting: false,
            hasApprovals: false,
            isDesktopActive: false,
            isIndexing: false
        ) == .starting)
    }

    @Test
    func `desktop beats indexing`() {
        // While live, desktop control outranks the sync mark so Emergency Stop
        // stays visible instead of hiding behind an index run.
        #expect(AppMenuLabel.labelState(
            isRunning: true,
            isServerFailed: false,
            isRestarting: false,
            hasApprovals: false,
            isDesktopActive: true,
            isIndexing: true
        ) == .desktop)
    }

    @Test
    func `indexing beats idle`() {
        // A live run with no higher claim reads as syncing, so the section
        // and the bar agree without a second selector.
        #expect(AppMenuLabel.labelState(
            isRunning: true,
            isServerFailed: false,
            isRestarting: false,
            hasApprovals: false,
            isDesktopActive: false,
            isIndexing: true
        ) == .indexing)
    }

    @Test
    func `idle when running with no activity`() {
        // Steady state with no claims falls through to the quiet default mark.
        #expect(AppMenuLabel.labelState(
            isRunning: true,
            isServerFailed: false,
            isRestarting: false,
            hasApprovals: false,
            isDesktopActive: false,
            isIndexing: false
        ) == .idle)
    }
}
