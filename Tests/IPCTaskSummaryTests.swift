// ABOUTME: Tests for IPC.TaskSummary — argument parsing and the completion/failure notice text.
// ABOUTME: Pure functions of an IPC.ProjectTask; no actor, no store, no socket.

@testable import Atelier
import XCTest

final class IPCTaskSummaryTests: XCTestCase {
    // MARK: - Tag parsing

    func test_tags_fromNil_isEmpty() {
        XCTAssertEqual(IPC.TaskSummary.tags(from: nil), [])
    }

    func test_tags_splitsOnCommasAndTrimsWhitespace() {
        XCTAssertEqual(IPC.TaskSummary.tags(from: "security, high , audit"), ["security", "high", "audit"])
    }

    func test_tags_dropsDuplicatesButKeepsFirstOrder() {
        XCTAssertEqual(IPC.TaskSummary.tags(from: "a,b,a,c"), ["a", "b", "c"])
    }

    // MARK: - The completion/failure notice

    private func task(state: IPC.TaskState) -> IPC.ProjectTask {
        IPC.ProjectTask(
            path: "audit/finding-1",
            name: "SQL injection",
            content: "irrelevant to the notice",
            tags: [],
            createdAt: Date().addingTimeInterval(-120),
            createdBySurfaceID: UUID().uuidString,
            state: state
        )
    }

    func test_notice_forACompletedTask_namesThePathAndName() {
        let notice = IPC.TaskSummary.notice(for: task(state: .completed(bySurfaceID: UUID().uuidString, at: Date())))
        XCTAssertTrue(notice.contains("audit/finding-1"), notice)
        XCTAssertTrue(notice.contains("SQL injection"), notice)
        XCTAssertTrue(notice.contains("completed"), notice)
    }

    func test_notice_forAFailedTask_includesTheReason() {
        let notice = IPC.TaskSummary.notice(for: task(state: .failed(bySurfaceID: UUID().uuidString, at: Date(), reason: "flaky dependency")))
        XCTAssertTrue(notice.contains("flaky dependency"), notice)
    }

    /// Task content is agent-chosen up to 64KB and must never be quoted in a
    /// notice — CLAUDE.md's own language for why applies verbatim: an
    /// oversized notice "is lost, silently, exactly when the agent is
    /// waiting for it."
    func test_notice_neverIncludesTaskContent() {
        let huge = String(repeating: "x", count: 10_000)
        let withHugeContent = IPC.ProjectTask(
            path: "audit/finding-1", name: "SQL injection", content: huge, tags: [],
            createdAt: Date().addingTimeInterval(-120), createdBySurfaceID: UUID().uuidString,
            state: .completed(bySurfaceID: UUID().uuidString, at: Date())
        )
        let notice = IPC.TaskSummary.notice(for: withHugeContent)
        XCTAssertFalse(notice.contains(huge))
        XCTAssertLessThan(notice.utf8.count, 1_000)
    }

    /// A pathological failure reason must not blow the notice past
    /// `IPC.Store`'s 64KB cap, which loses it silently rather than trimming.
    func test_notice_clipsAnOversizedReason() {
        let hugeReason = String(repeating: "y", count: 10_000)
        let notice = IPC.TaskSummary.notice(for: task(state: .failed(bySurfaceID: UUID().uuidString, at: Date(), reason: hugeReason)))
        XCTAssertLessThan(notice.utf8.count, 2_000)
        XCTAssertTrue(notice.hasSuffix("…"), notice)
    }
}
