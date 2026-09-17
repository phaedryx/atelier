// ABOUTME: Tests for the session-checkpoint store: round-trip, overwrite, the size cap, and
// ABOUTME: the undecodable-blob discard that keeps a stale write from reading as a hard failure.

@testable import Atelier
import XCTest

final class IPCCheckpointStoreTests: XCTestCase {
    func test_store_roundTripsContentAndUpdatedAt() throws {
        let id = UUID()
        addTeardownBlock { IPC.CheckpointStore.clear(for: id) }

        let before = Date()
        try IPC.CheckpointStore.save("finished the login form, tests still red", for: id)
        let after = Date()

        let read = try XCTUnwrap(IPC.CheckpointStore.read(for: id))
        XCTAssertEqual(read.content, "finished the login form, tests still red")
        XCTAssertGreaterThanOrEqual(read.updatedAt, before)
        XCTAssertLessThanOrEqual(read.updatedAt, after)
    }

    /// No history: the second save is what a read returns, not both.
    func test_store_saveOverwritesRatherThanAppending() throws {
        let id = UUID()
        addTeardownBlock { IPC.CheckpointStore.clear(for: id) }

        try IPC.CheckpointStore.save("first note", for: id)
        try IPC.CheckpointStore.save("second note", for: id)

        XCTAssertEqual(IPC.CheckpointStore.read(for: id)?.content, "second note")
    }

    func test_store_isNilForAWorkstreamThatHasNeverSaved() {
        XCTAssertNil(IPC.CheckpointStore.read(for: UUID()))
    }

    func test_store_clearRemovesTheKeyEntirely() throws {
        let id = UUID()
        try IPC.CheckpointStore.save("note", for: id)

        IPC.CheckpointStore.clear(for: id)

        XCTAssertNil(IPC.CheckpointStore.read(for: id))
        XCTAssertNil(UserDefaults.standard.object(forKey: IPC.CheckpointStore.key(for: id)))
    }

    /// A checkpoint an agent believes it saved in full must never be silently
    /// truncated — refused outright instead, mirroring `IPC.Store`'s message cap.
    func test_store_refusesContentOverTheCap() {
        let id = UUID()
        let tooBig = String(repeating: "a", count: IPC.CheckpointStore.maxContentSize + 1)

        XCTAssertThrowsError(try IPC.CheckpointStore.save(tooBig, for: id)) { error in
            XCTAssertEqual(error as? IPC.CheckpointStore.Error, .contentTooLarge)
        }
        XCTAssertNil(IPC.CheckpointStore.read(for: id), "a refused save must not partially write")
    }

    func test_store_acceptsContentExactlyAtTheCap() throws {
        let id = UUID()
        addTeardownBlock { IPC.CheckpointStore.clear(for: id) }
        let exactlyAtCap = String(repeating: "a", count: IPC.CheckpointStore.maxContentSize)

        try IPC.CheckpointStore.save(exactlyAtCap, for: id)

        XCTAssertEqual(IPC.CheckpointStore.read(for: id)?.content.utf8.count, IPC.CheckpointStore.maxContentSize)
    }

    /// The same ruling `Verification.CheckStore.records` makes for its own blob: a
    /// write from a build whose model has since changed is dropped, not surfaced —
    /// and it must read as "nothing saved yet," not as a decode failure.
    func test_store_discardsAnUndecodableBlobRatherThanThrowing() {
        let id = UUID()
        addTeardownBlock { IPC.CheckpointStore.clear(for: id) }
        UserDefaults.standard.set(Data("not json".utf8), forKey: IPC.CheckpointStore.key(for: id))

        XCTAssertNil(IPC.CheckpointStore.read(for: id))
    }

    /// One key per workstream — so two workstreams cannot collide.
    func test_store_keysByWorkstreamOnly() {
        let id = UUID()
        XCTAssertEqual(
            IPC.CheckpointStore.key(for: id),
            "atelier.sessionCheckpoint." + id.uuidString.lowercased()
        )
    }
}
