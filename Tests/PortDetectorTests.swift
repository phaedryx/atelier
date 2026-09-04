// ABOUTME: Tests for Port.Detector's filesystem watching of atelier-run state files.
// ABOUTME: Covers the file watcher surviving the atomic rewrites RunState.Store performs.

@testable import Atelier
import XCTest

final class PortDetectorTests: XCTestCase {
    private var workstreamID: UUID!

    override func setUpWithError() throws {
        workstreamID = UUID()
        try FileManager.default.createDirectory(
            at: RunState.Store.directoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        RunState.Store.remove(for: workstreamID)
    }

    private func writeState(selectedPort: Int?) throws {
        try RunState.Store.write(
            RunState.Snapshot(
                pid: ProcessInfo.processInfo.processIdentifier,
                status: .running,
                detectedPorts: selectedPort.map { [$0] } ?? [],
                selectedPort: selectedPort,
                startedAt: Date()
            ),
            for: workstreamID
        )
    }

    private func inode(ofFileFor id: UUID) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: RunState.Store.fileURL(for: id).path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
    }

    /// `RunState.Store.write` goes through `FilePersistence.writeAtomically`, i.e.
    /// `replaceItemAt` → rename, so the very first write replaces the inode the
    /// watcher opened. The watcher used to hold that dead inode forever: its handler
    /// only called `refreshState`, which re-attaches solely when the state file is
    /// *missing*, and `attachFileWatcherIfNeeded` early-returns while `fileSource`
    /// is non-nil. Detection kept working only because the directory watcher covered it.
    func testTheFileWatcherFollowsTheAtomicRewriteToTheNewInode() throws {
        try writeState(selectedPort: 3000)
        let detector = Port.Detector(workstreamID: workstreamID)

        let originalInode = try inode(ofFileFor: workstreamID)
        XCTAssertEqual(detector._testWatchedInode(), originalInode, "Precondition: watching the file that exists now")

        try writeState(selectedPort: 3001)
        let replacedInode = try inode(ofFileFor: workstreamID)
        XCTAssertNotEqual(replacedInode, originalInode, "Precondition: the write must be atomic, replacing the inode")

        let followed = expectation(description: "watcher re-attaches to the live inode")
        pollUntil(followed) { detector._testWatchedInode() == replacedInode }
        wait(for: [followed], timeout: 5)

        XCTAssertEqual(
            detector._testWatchedInode(), replacedInode,
            "The watcher must not be left holding a replaced inode"
        )
    }

    func testTheDetectorReportsAPortWrittenBeforeItStarted() throws {
        try writeState(selectedPort: 4100)
        let detector = Port.Detector(workstreamID: workstreamID)

        let reported = expectation(description: "port reported")
        pollUntil(reported) { detector.selectedPort == 4100 && detector.status == .running }
        wait(for: [reported], timeout: 5)
    }

    /// The point of the fix: a second write must still be observed by the *file*
    /// watcher, not only by the directory watcher that happened to be masking it.
    func testASecondWriteIsStillObserved() throws {
        try writeState(selectedPort: 4200)
        let detector = Port.Detector(workstreamID: workstreamID)

        let first = expectation(description: "first port")
        pollUntil(first) { detector.selectedPort == 4200 }
        wait(for: [first], timeout: 5)

        try writeState(selectedPort: 4201)
        let second = expectation(description: "second port")
        pollUntil(second) { detector.selectedPort == 4201 }
        wait(for: [second], timeout: 5)
    }

    private func pollUntil(_ expectation: XCTestExpectation, _ condition: @escaping () -> Bool) {
        func check() {
            if condition() {
                expectation.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
            }
        }
        DispatchQueue.main.async(execute: check)
    }
}
