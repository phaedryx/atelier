// ABOUTME: Tests for the per-check result store: round-trip, overwrite by name, and
// ABOUTME: the undecodable-blob discard that keeps a stale write from breaking the tab.

@testable import Atelier
import XCTest

final class VerificationCheckStoreTests: XCTestCase {
    private func record(
        _ name: String, state: Verification.CheckResult.State, runID: String = "abcd1234"
    ) -> Verification.CheckRecord {
        Verification.CheckRecord(
            name: name, state: state, duration: 1.5,
            stamp: "head|1|digest", runID: runID, completedAt: Date(timeIntervalSince1970: 100)
        )
    }

    func test_store_roundTripsRecordsByName() {
        let id = UUID()
        addTeardownBlock { Verification.CheckStore.clear(for: id) }

        Verification.CheckStore.save(
            ["rspec": record("rspec", state: .failed(1)), "rubocop": record("rubocop", state: .passed)],
            for: id
        )

        let read = Verification.CheckStore.records(for: id)
        XCTAssertEqual(read["rspec"]?.state, .failed(1))
        XCTAssertEqual(read["rubocop"]?.state, .passed)
        XCTAssertEqual(read["rspec"]?.stamp, "head|1|digest")
        XCTAssertEqual(read["rspec"]?.runID, "abcd1234")
    }

    func test_store_isEmptyForAWorkstreamThatHasNeverRun() {
        XCTAssertTrue(Verification.CheckStore.records(for: UUID()).isEmpty)
    }

    func test_store_clearRemovesTheKeyEntirely() {
        let id = UUID()
        Verification.CheckStore.save(["rspec": record("rspec", state: .passed)], for: id)
        Verification.CheckStore.clear(for: id)

        XCTAssertTrue(Verification.CheckStore.records(for: id).isEmpty)
        XCTAssertNil(UserDefaults.standard.object(forKey: Verification.CheckStore.key(for: id)))
    }

    /// The same guarantee `Verification.Store.latest` gives: a blob written by a build
    /// whose model has since changed is dropped, not surfaced. A throw here would break
    /// the tab for a convenience.
    func test_store_discardsAnUndecodableBlobRatherThanThrowing() {
        let id = UUID()
        addTeardownBlock { Verification.CheckStore.clear(for: id) }
        UserDefaults.standard.set(
            Data("not json".utf8), forKey: Verification.CheckStore.key(for: id)
        )

        XCTAssertTrue(Verification.CheckStore.records(for: id).isEmpty)
    }

    /// One key per workstream, not one per check — so two workstreams cannot collide and
    /// a check name can never become part of a defaults key.
    func test_store_keysByWorkstreamOnly() {
        let id = UUID()
        XCTAssertEqual(
            Verification.CheckStore.key(for: id),
            "atelier.verifyChecks." + id.uuidString.lowercased()
        )
    }
}
