// ABOUTME: Tests for Port.Detector's filesystem watching of atelier-run state files.
// ABOUTME: Covers the file watcher surviving the atomic rewrites RunState.Store performs.

@testable import Atelier
import Combine
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

    /// A pid guaranteed not to be running, for exercising the dead-pid branch of
    /// `loadValidated` deterministically rather than guessing at an unused number.
    private func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// Defect B: `runMonitor` used to write a `.stopped` snapshot and then immediately
    /// remove the very same file. `loadValidated` rejects any snapshot whose pid is not
    /// running, and by the time a run's process has stopped that pid is already dead — so
    /// the `.stopped` write could never be observed as anything other than what plain
    /// removal already produces. This pins that equivalence: a `.stopped` snapshot for a
    /// dead pid reads exactly like no file at all.
    func testAStoppedSnapshotForADeadPIDReadsIdenticallyToNoFile() throws {
        let pid = try deadPID()
        try RunState.Store.write(
            RunState.Snapshot(
                pid: pid,
                status: .stopped,
                detectedPorts: [4300],
                selectedPort: 4300,
                startedAt: Date()
            ),
            for: workstreamID
        )

        XCTAssertNil(RunState.Store.loadValidated(for: workstreamID))

        RunState.Store.remove(for: workstreamID)
        XCTAssertNil(RunState.Store.loadValidated(for: workstreamID))
    }

    /// Defect B, from the consumer's side: with no `.stopped` snapshot ever written, a
    /// caller watching the store — `Port.Detector` — must still observe the run ending.
    /// Removing the file is the whole signal; this asserts that removal alone drives the
    /// detector back to `.none` with no selected port.
    func testDetectorReadsNoSessionOnceTheRunStateFileIsRemoved() throws {
        try writeState(selectedPort: 4400)
        let detector = Port.Detector(workstreamID: workstreamID)

        let running = expectation(description: "port reported")
        pollUntil(running) { detector.selectedPort == 4400 && detector.status == .running }
        wait(for: [running], timeout: 5)

        RunState.Store.remove(for: workstreamID)

        let stopped = expectation(description: "run reported as ended")
        pollUntil(stopped) { detector.status == .none && detector.selectedPort == nil }
        wait(for: [stopped], timeout: 5)
    }

    /// The efficiency fix: a rewrite that changes nothing observable (the case that
    /// keeps recurring for a `selectedPort` that never resolves, see
    /// `RunState.PortSelectionTracker.candidatePort`) must not fire `objectWillChange`.
    /// Confirming the rewrite was actually observed (via the inode change) is what
    /// keeps this from passing vacuously because the watcher simply hadn't noticed yet.
    func testRefreshStateDoesNotRepublishWhenTheSnapshotIsUnchanged() throws {
        try writeState(selectedPort: 4500)
        let detector = Port.Detector(workstreamID: workstreamID)

        let running = expectation(description: "port reported")
        pollUntil(running) { detector.selectedPort == 4500 && detector.status == .running }
        wait(for: [running], timeout: 5)

        let originalInode = try inode(ofFileFor: workstreamID)

        var changeCount = 0
        let cancellable = detector.objectWillChange.sink { changeCount += 1 }
        defer { cancellable.cancel() }

        try writeState(selectedPort: 4500)

        let rewritten = expectation(description: "watcher observes the identical rewrite")
        pollUntil(rewritten) { (try? self.inode(ofFileFor: self.workstreamID)) != originalInode }
        wait(for: [rewritten], timeout: 5)

        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        XCTAssertEqual(changeCount, 0, "Republishing an identical snapshot must not fire objectWillChange")
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
