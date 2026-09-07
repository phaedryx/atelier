// ABOUTME: Tests for the permission-approval store, the request model, and its settings.
// ABOUTME: The invariant under test throughout: every request that goes in comes back out exactly once.

@testable import Atelier
import XCTest

@MainActor
final class PermissionApprovalStoreTests: XCTestCase {
    private var store: PermissionApprovalStore!
    private let wsID = UUID()

    override func setUp() {
        super.setUp()
        // A fresh store per test rather than the singleton: these resolvers stand
        // in for real blocked agents, and leaking one between cases would be
        // indistinguishable from the bug this file exists to catch.
        store = PermissionApprovalStore()
    }

    override func tearDown() {
        store.resetForTesting()
        store = nil
        super.tearDown()
    }

    private func request(
        expiresIn: TimeInterval = 60,
        tool: String = "Bash",
        surfaceID: UUID? = nil
    ) -> PendingPermission {
        PendingPermission(
            id: UUID(),
            toolName: tool,
            detail: "echo hello",
            surfaceID: surfaceID,
            receivedAt: Date(),
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    // MARK: - Answering

    func test_answering_resolvesWithTheDecisionAndDropsTheRequest() {
        var decisions: [PendingPermission.Decision?] = []
        let pending = request()
        store.enqueue(pending, in: wsID) { decisions.append($0) }

        XCTAssertEqual(store.frontmost(for: wsID), pending)
        store.answer(pending.id, with: .deny)

        XCTAssertEqual(decisions, [.deny])
        XCTAssertNil(store.frontmost(for: wsID))
        XCTAssertEqual(store.count(for: wsID), 0)
    }

    func test_answeringTwice_resolvesOnce() {
        var calls = 0
        let pending = request()
        store.enqueue(pending, in: wsID) { _ in calls += 1 }

        store.answer(pending.id, with: .allow)
        store.answer(pending.id, with: .deny)

        XCTAssertEqual(calls, 1, "a second answer would write onto a connection that is already closed")
    }

    func test_onAnswered_firesForAnExplicitAnswerOnly() {
        var answered: [UUID] = []
        store.onAnswered = { answered.append($0) }

        let first = request()
        store.enqueue(first, in: wsID) { _ in }
        store.answer(first.id, with: .allow)
        XCTAssertEqual(answered, [wsID])

        // Releasing is not answering: the user is still being asked, in the
        // terminal, so the row must keep reporting that.
        let second = request()
        store.enqueue(second, in: wsID) { _ in }
        store.releaseAll(workstreamID: wsID)
        XCTAssertEqual(answered, [wsID])
    }

    // MARK: - Expiry

    func test_expiry_resolvesWithNoDecision() {
        var decisions: [PendingPermission.Decision?] = []
        let expectation = expectation(description: "hold expired")
        let pending = request(expiresIn: 0.2)
        store.enqueue(pending, in: wsID) {
            decisions.append($0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(decisions.count, 1)
        XCTAssertNil(decisions[0], "no decision is what lets Claude Code ask in the terminal")
        XCTAssertNil(store.frontmost(for: wsID))
    }

    func test_answeringAfterExpiry_doesNothing() {
        var calls = 0
        let expectation = expectation(description: "hold expired")
        let pending = request(expiresIn: 0.2)
        store.enqueue(pending, in: wsID) { _ in
            calls += 1
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        store.answer(pending.id, with: .allow)
        XCTAssertEqual(calls, 1)
    }

    /// A request whose deadline has already passed still has to be resolved, not
    /// dropped — a negative interval must schedule immediately, not never.
    func test_anAlreadyExpiredRequestIsStillResolved() {
        let expectation = expectation(description: "resolved")
        store.enqueue(request(expiresIn: -30), in: wsID) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Queueing

    func test_twoRequestsInOneWorkstreamQueueOldestFirst() {
        let first = request(tool: "Bash")
        let second = request(tool: "Write")
        store.enqueue(first, in: wsID) { _ in }
        store.enqueue(second, in: wsID) { _ in }

        XCTAssertEqual(store.count(for: wsID), 2)
        XCTAssertEqual(store.frontmost(for: wsID), first, "the second must not displace the first")

        store.answer(first.id, with: .allow)
        XCTAssertEqual(store.frontmost(for: wsID), second)
    }

    // MARK: - Release

    func test_releaseAll_handsBackEveryRequestInTheWorkstream() {
        var decisions: [PendingPermission.Decision?] = []
        store.enqueue(request(), in: wsID) { decisions.append($0) }
        store.enqueue(request(), in: wsID) { decisions.append($0) }

        store.releaseAll(workstreamID: wsID)

        XCTAssertEqual(decisions.count, 2)
        XCTAssertTrue(decisions.allSatisfy { $0 == nil })
        XCTAssertEqual(store.count(for: wsID), 0)
    }

    func test_releaseAll_leavesOtherWorkstreamsAlone() {
        let other = UUID()
        var released = 0
        store.enqueue(request(), in: wsID) { _ in released += 1 }
        store.enqueue(request(), in: other) { _ in released += 1 }

        store.releaseAll(workstreamID: wsID)

        XCTAssertEqual(released, 1)
        XCTAssertEqual(store.count(for: other), 1)
    }

    func test_releaseEverything_handsBackAcrossWorkstreams() {
        var decisions: [PendingPermission.Decision?] = []
        store.enqueue(request(), in: wsID) { decisions.append($0) }
        store.enqueue(request(), in: UUID()) { decisions.append($0) }

        store.releaseEverything()

        XCTAssertEqual(decisions.count, 2, "an agent blocked on an app that is quitting must be handed back")
        XCTAssertTrue(decisions.allSatisfy { $0 == nil })
    }
}

// MARK: - Request rendering

final class PendingPermissionDetailTests: XCTestCase {
    func test_bashShowsTheCommand() {
        XCTAssertEqual(
            PendingPermission.detail(toolName: "Bash", toolInput: ["command": "rm -rf build\n"]),
            "rm -rf build"
        )
    }

    func test_writesShowThePath() {
        XCTAssertEqual(
            PendingPermission.detail(toolName: "Edit", toolInput: ["file_path": "/repo/Foo.swift"]),
            "/repo/Foo.swift"
        )
        XCTAssertEqual(
            PendingPermission.detail(toolName: "NotebookEdit", toolInput: ["notebook_path": "/repo/a.ipynb"]),
            "/repo/a.ipynb"
        )
    }

    func test_toolNamesAreMatchedRegardlessOfCase() {
        XCTAssertEqual(PendingPermission.detail(toolName: "bash", toolInput: ["command": "ls"]), "ls")
    }

    /// A tool nobody has written a case for still has to say what it is about to
    /// do — "unknown tool" with a blank body is not something anyone can answer.
    func test_anUnknownToolFallsBackToItsScalarFields() {
        let detail = PendingPermission.detail(
            toolName: "mcp__thing__doIt",
            toolInput: ["target": "prod", "count": 3, "nested": ["a": 1]]
        )
        XCTAssertEqual(detail, "count: 3\ntarget: prod", "nested values are summarised away, not serialised")
    }

    func test_noInputReadsAsNoDetail() {
        XCTAssertNil(PendingPermission.detail(toolName: "Bash", toolInput: nil))
        XCTAssertNil(PendingPermission.detail(toolName: "Bash", toolInput: [:]))
        XCTAssertNil(PendingPermission.detail(toolName: "Bash", toolInput: ["command": "   "]))
    }
}

// MARK: - Settings

final class PermissionApprovalSettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PermissionApprovalSettings.holdKey)
        UserDefaults.standard.removeObject(forKey: PermissionApprovalSettings.enabledKey)
        super.tearDown()
    }

    func test_isOffUntilTurnedOn() {
        UserDefaults.standard.removeObject(forKey: PermissionApprovalSettings.enabledKey)
        XCTAssertFalse(PermissionApprovalSettings.isEnabled, "holding an agent is opt-in")
    }

    func test_anUnsetHoldIsTheDefaultNotZero() {
        UserDefaults.standard.removeObject(forKey: PermissionApprovalSettings.holdKey)
        XCTAssertEqual(PermissionApprovalSettings.hold, PermissionApprovalSettings.defaultHold)
    }

    /// The value decides how long an agent can sit blocked on a window nobody is
    /// watching, and `defaults write` reaches it.
    func test_theHoldIsClampedAtBothEnds() {
        UserDefaults.standard.set(1, forKey: PermissionApprovalSettings.holdKey)
        XCTAssertEqual(PermissionApprovalSettings.hold, PermissionApprovalSettings.minimumHold)

        UserDefaults.standard.set(86400, forKey: PermissionApprovalSettings.holdKey)
        XCTAssertEqual(PermissionApprovalSettings.hold, PermissionApprovalSettings.maximumHold)
    }

    func test_aValueInRangeIsUsedAsGiven() {
        UserDefaults.standard.set(120, forKey: PermissionApprovalSettings.holdKey)
        XCTAssertEqual(PermissionApprovalSettings.hold, 120)
    }
}
