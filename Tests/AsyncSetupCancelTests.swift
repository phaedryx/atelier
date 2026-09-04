// ABOUTME: Tests for cancelBootstrap's two exits: no binary to shut down, and cancellation.
// ABOUTME: Both used to run the full 30s poll before letting the archive proceed.

@testable import Atelier
import XCTest

final class AsyncSetupCancelTests: XCTestCase {
    /// `shutDown` is the only thing that can make the bootstrap stop, so with no
    /// binary the poll below cannot change its answer — it burned all 300
    /// iterations and then archived anyway.
    func testReturnsWithoutWaitingWhenThereIsNoBinary() async {
        let service = AsyncSetupService()
        let id = UUID()
        await service._markBootstrapRunning(id)

        let started = Date()
        let outcome = await service.cancelBootstrap(for: id, binary: nil, worktreePath: "/tmp/does-not-matter")

        XCTAssertEqual(outcome, .noBinary)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            5,
            "With no binary there is nothing to wait for"
        )
    }

    func testReportsThatNothingWasRunning() async {
        let service = AsyncSetupService()
        let outcome = await service.cancelBootstrap(
            for: UUID(), binary: nil, worktreePath: "/tmp/does-not-matter"
        )
        XCTAssertEqual(outcome, .notRunning)
    }

    /// The poll used `try? await Task.sleep`, which swallows `CancellationError`:
    /// a cancelled task made every sleep return instantly and the loop spun
    /// through all 300 iterations as fast as the CPU allowed.
    func testStopsPollingWhenTheTaskIsCancelled() async {
        let service = AsyncSetupService()
        let id = UUID()
        await service._markBootstrapRunning(id)

        let started = Date()
        let task = Task {
            await service.cancelBootstrap(
                for: id,
                binary: "/nonexistent/process-compose",
                worktreePath: "/tmp/does-not-matter"
            )
        }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled, "A cancelled wait must stop, not spin out its 300 iterations")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
