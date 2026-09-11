@testable import Atelier
import XCTest

final class VerificationStoreTests: XCTestCase {
    private let workstreamID = UUID()

    override func tearDown() {
        Verification.Store.clear(for: workstreamID)
        Verification.setSelected([], for: workstreamID)
        super.tearDown()
    }

    private func run(id: String, stamp: String) -> Verification.Run {
        Verification.Run(
            id: id, workstreamID: workstreamID, startedAt: Date(), stamp: stamp,
            checks: [.init(name: "rspec", state: .failed(1), duration: 3, output: "boom")],
            wasStopped: false
        )
    }

    func test_save_thenLatestRoundTrips() {
        Verification.Store.save(run(id: "abcd1234", stamp: "head|10|deadbeef"))
        let stored = Verification.Store.latest(for: workstreamID)
        XCTAssertEqual(stored?.id, "abcd1234")
        XCTAssertEqual(stored?.stamp, "head|10|deadbeef")
        XCTAssertEqual(stored?.checks.first?.state, .failed(1))
        XCTAssertEqual(stored?.checks.first?.output, "boom")
    }

    func test_save_keepsOnlyTheMostRecentRun() {
        Verification.Store.save(run(id: "aaaa1111", stamp: "s1"))
        Verification.Store.save(run(id: "bbbb2222", stamp: "s2"))
        XCTAssertEqual(Verification.Store.latest(for: workstreamID)?.id, "bbbb2222")
    }

    func test_latest_isNilForAnUnknownWorkstream() {
        XCTAssertNil(Verification.Store.latest(for: UUID()))
    }

    func test_keys_areScopedPerWorkstreamAndPrefixed() {
        XCTAssertNotEqual(Verification.Store.key(for: UUID()), Verification.Store.key(for: UUID()))
        XCTAssertTrue(Verification.Store.key(for: workstreamID).hasPrefix("atelier."))
        XCTAssertTrue(Verification.selectionKey(for: workstreamID).hasPrefix("atelier.verifySelection."))
    }

    /// Empty means all, and "all" is stored as the absence of a value — the
    /// convention ProcessCompose.TableModel already uses, so a project adding a
    /// check to its YAML picks it up automatically.
    func test_setSelected_emptyRemovesTheKey() {
        Verification.setSelected(["rspec"], for: workstreamID)
        XCTAssertEqual(Verification.selected(for: workstreamID), ["rspec"])
        Verification.setSelected([], for: workstreamID)
        XCTAssertEqual(Verification.selected(for: workstreamID), [])
        XCTAssertNil(UserDefaults.standard.object(forKey: Verification.selectionKey(for: workstreamID)))
    }

    /// The verify selection must not share Execution's key.
    func test_selectionKey_differsFromTheExecuteSelectionKey() {
        XCTAssertNotEqual(
            Verification.selectionKey(for: workstreamID),
            ProcessCompose.TableModel.selectionKey(for: workstreamID)
        )
    }

    /// An encode failure (e.g. NaN in duration) must not crash and must log.
    /// Because a failed save leaves the prior run in the store, it is worth
    /// logging audibly rather than silently. This test confirms save() does not
    /// throw and does not corrupt the store on an encode failure.
    func test_save_withNaNDurationLogsButDoesNotCrash() {
        // Set a prior run to confirm the stale one persists.
        Verification.Store.save(run(id: "prior", stamp: "s1"))

        // Create a run with NaN duration, which JSONEncoder rejects by default.
        var badRun = run(id: "failing", stamp: "s2")
        badRun.checks[0].duration = Double.nan

        // save() must not throw.
        Verification.Store.save(badRun)

        // The store should still hold the prior run, not the one that failed.
        XCTAssertEqual(Verification.Store.latest(for: workstreamID)?.id, "prior")
    }
}
