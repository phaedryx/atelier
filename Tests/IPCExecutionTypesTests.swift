// ABOUTME: Pins the execution wire types and the log tail's byte budget.
// ABOUTME: The trim is a pure function, so the budget is assertable without a socket.

@testable import Atelier
import XCTest

final class IPCExecutionTypesTests: XCTestCase {
    // MARK: - The log trim

    func test_trimmed_keepsEverythingUnderBudget() {
        let result = IPC.ExecutionLogs.trimmed(lines: ["a", "b", "c"], budgetBytes: 1024)
        XCTAssertEqual(result.lines, ["a", "b", "c"])
        XCTAssertFalse(result.wasTrimmed)
    }

    func test_trimmed_ofNothing_isNothingAndIsNotATrim() {
        let result = IPC.ExecutionLogs.trimmed(lines: [], budgetBytes: 1024)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertFalse(result.wasTrimmed)
    }

    /// A tail keeps the NEWEST lines, so an over-budget tail drops from the front.
    func test_trimmed_dropsOldestFirst() {
        let filler = String(repeating: "x", count: 10)
        let result = IPC.ExecutionLogs.trimmed(lines: ["oldest", filler, "newest"], budgetBytes: 20)
        XCTAssertEqual(result.lines.last, "newest")
        XCTAssertFalse(result.lines.contains("oldest"))
        XCTAssertTrue(result.wasTrimmed)
    }

    /// One line past the whole budget must still answer something: an empty list
    /// reads as "this process printed nothing", which is a different and wrong
    /// answer.
    func test_trimmed_keepsTheNewestLineEvenWhenItAloneExceedsTheBudget() {
        let huge = String(repeating: "y", count: 500)
        let result = IPC.ExecutionLogs.trimmed(lines: ["old", huge], budgetBytes: 100)
        XCTAssertEqual(result.lines, [huge])
        XCTAssertTrue(result.wasTrimmed)
    }

    /// The budget is bytes, not characters — a multi-byte line must not slip
    /// past it.
    func test_trimmed_countsUTF8BytesRatherThanCharacters() {
        // Four characters, twelve UTF-8 bytes.
        let wide = "日本語語"
        let result = IPC.ExecutionLogs.trimmed(lines: [wide, wide], budgetBytes: 20)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.wasTrimmed)
    }

    // MARK: - The wire

    func test_executionInfo_roundTripsThroughJSON() throws {
        let info = IPC.ExecutionInfo(
            state: .running,
            unavailableReason: nil,
            declaredProcesses: ["web", "api"],
            processes: [
                IPC.ExecutionProcessInfo(
                    name: "web", namespace: "execute", status: "Running", isReady: "Ready",
                    hasReadyProbe: true, restarts: 0, exitCode: 0, pid: 4242, isRunning: true,
                    port: "4100"
                ),
            ],
            command: "execution.process-compose.yaml"
        )
        let data = try JSONEncoder().encode(IPC.Payload.execution(info))
        let decoded = try JSONDecoder().decode(IPC.Payload.self, from: data)
        guard case let .execution(round) = decoded else { return XCTFail("wrong payload case") }
        XCTAssertEqual(round, info)
    }

    func test_executionLogs_roundTripsThroughJSON() throws {
        let logs = IPC.ExecutionLogs(process: "web", lines: ["boom"], wasTrimmed: true)
        let data = try JSONEncoder().encode(IPC.Payload.executionLogs(logs))
        let decoded = try JSONDecoder().decode(IPC.Payload.self, from: data)
        guard case let .executionLogs(round) = decoded else { return XCTFail("wrong payload case") }
        XCTAssertEqual(round, logs)
    }

    /// All four states must survive the wire under stable names — collapsing any
    /// of them is the bug this enum exists to prevent.
    func test_everyRunStateHasAStableWireName() {
        XCTAssertEqual(
            Set(IPC.ExecutionRunState.allCases.map(\.rawValue)),
            ["unavailable", "idle", "running", "running_without_process_table"]
        )
    }
}
