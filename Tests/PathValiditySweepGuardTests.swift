// ABOUTME: Tests for the one-at-a-time admission rule on AppEnvironment's path-validity sweep.
// ABOUTME: Pins that a lost completion self-heals rather than disabling the sweep for the session.

@testable import Atelier
import XCTest

@MainActor
final class PathValiditySweepGuardTests: XCTestCase {
    /// Nothing in flight: the ordinary case, every 15 seconds.
    func testAdmitsASweepWhenNoneIsInFlight() {
        XCTAssertTrue(AppEnvironment.admitsPathValiditySweep(inFlightSince: nil))
    }

    /// The bug this guard exists for: `ContentView`'s 15-second timer spawned a
    /// fresh `Task.detached` unconditionally, so a sweep that outlived its own
    /// period stacked — and each sweep parks a thread per worktree in
    /// `ProcessRunner.capture` for the life of its child.
    func testRefusesASweepWhileOneIsInFlight() {
        let now = Date()
        XCTAssertFalse(
            AppEnvironment.admitsPathValiditySweep(
                inFlightSince: now.addingTimeInterval(-20),
                now: now
            ),
            "a second sweep was admitted 20s into the first"
        )
    }

    /// The reason the guard is a timestamp and not a `Bool`.
    ///
    /// A flag cleared in the completion block fails in the worst available
    /// direction: a detached task that dies before reaching it would disable the
    /// sweep for the rest of the session — worse than the stacking being
    /// prevented, and silent. Past the ceiling, a sweep whose completion never
    /// arrived stops blocking its successors.
    func testAdmitsASweepOnceTheCeilingHasPassed() {
        let now = Date()
        let lost = now.addingTimeInterval(-(AppEnvironment.pathValiditySweepCeiling + 1))

        XCTAssertTrue(
            AppEnvironment.admitsPathValiditySweep(inFlightSince: lost, now: now),
            "a sweep that lost its completion has disabled every later one"
        )
    }

    /// The ceiling has to sit above the deadline that bounds the sweep's own
    /// probes, or it fires for a sweep that is merely slow — turning the guard
    /// into the stacking it prevents, one tick later.
    func testCeilingClearsTheDeadlineBoundingTheSweepsOwnProbes() {
        XCTAssertGreaterThan(
            AppEnvironment.pathValiditySweepCeiling,
            ProcessRunner.Timeout.local,
            "a sweep running its probes out to their deadline would be declared lost"
        )
    }
}
