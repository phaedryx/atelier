// ABOUTME: Tests for IPC.TaskSummary — argument parsing and the completion/failure notice text.
// ABOUTME: Pure functions of an IPC.ProjectTask; no actor, no store, no socket.

@testable import Atelier
import XCTest

final class IPCTaskSummaryTests: XCTestCase {
    // MARK: - Tag parsing

    /// Through the reader `addTask` actually calls. `TaskSummary.tags(from:)`
    /// was a one-line delegation to `ToolArguments.parseList` with no production
    /// caller left, kept alive only by these tests.
    private func tags(_ raw: String?) -> [String] {
        IPC.ToolArguments(
            tool: .addTask,
            raw: raw.map { ["tags": $0] } ?? [:]
        ).list("tags")
    }

    func test_tags_fromNil_isEmpty() {
        XCTAssertEqual(tags(nil), [])
    }

    func test_tags_splitsOnCommasAndTrimsWhitespace() {
        XCTAssertEqual(tags("security, high , audit"), ["security", "high", "audit"])
    }

    func test_tags_dropsDuplicatesButKeepsFirstOrder() {
        XCTAssertEqual(tags("a,b,a,c"), ["a", "b", "c"])
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

    /// An oversized task path must not blow the notice past the 64KB cap.
    /// Path is agent-chosen with no length validation in the store.
    func test_notice_clipsAnOversizedPath() {
        let hugePath = String(repeating: "z", count: 10_000)
        let baseTask = task(state: .completed(bySurfaceID: UUID().uuidString, at: Date()))
        let withHugePath = IPC.ProjectTask(
            path: hugePath, name: baseTask.name, content: baseTask.content, tags: baseTask.tags,
            createdAt: baseTask.createdAt, createdBySurfaceID: baseTask.createdBySurfaceID, state: baseTask.state
        )
        let notice = IPC.TaskSummary.notice(for: withHugePath)
        XCTAssertLessThan(notice.utf8.count, 2_000)
    }
}
