// ABOUTME: IPC.Service's seven execution tools, over the IPC.ExecutionControlling seam.
// ABOUTME: Reads and drives the dev stack; no completion notices, deliberately.

import Foundation

extension IPC.Service {
    // MARK: - Execution

    /// Default and ceiling for a log tail.
    ///
    /// The ceiling is not tuning: one unbounded line is enough to reach
    /// `IPC.Server.maxFrameBytes`, and `ExecutionLogs.trimmed`'s byte budget
    /// is the second bound. Clamped rather than refused — a caller asking for
    /// more lines than exist is not making a mistake, and the cap is
    /// Atelier's bound rather than the project's.
    private static let defaultLogTail = 100
    private static let maxLogTail = 1000

    func listProcesses(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let controller = execution else {
            return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
        }
        do {
            return try await .success(id: request.id, .execution(controller.executionState(in: workstreamID)))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func readProcessLogs(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let controller = execution else {
            return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
        }
        let arguments = ToolArguments(request)
        do {
            let name = try arguments.nonEmpty("process")
            let asked = try arguments.integer("tail") ?? Self.defaultLogTail
            let tail = min(max(asked, 1), Self.maxLogTail)
            return try await .success(
                id: request.id,
                .executionLogs(controller.processLogs(in: workstreamID, name: name, tail: tail))
            )
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func controlProcess(for request: Request, action: ProcessAction) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let controller = execution else {
            return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
        }
        do {
            let name = try ToolArguments(request).nonEmpty("process")
            try await controller.controlProcess(in: workstreamID, name: name, action: action)
            return .success(id: request.id, .text("\(action.rawValue) \(name): done."))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func startExecution(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let controller = execution else {
            return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
        }
        let processes = ToolArguments(request).list("processes")
        do {
            let start = try await controller.startExecution(in: workstreamID, processes: processes)
            return .success(id: request.id, .text(Self.startAnswer(for: start)))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// The answer a start gets.
    ///
    /// It says "poll" in as many words, because there are no completion
    /// notices on this surface and an agent that waits for one waits for the
    /// rest of the session. It also says the tab was opened but not selected,
    /// the same thing `open_tab`'s answer says and for the same reason: an
    /// agent that reads "opened" as "they are looking at it" waits for a
    /// reaction nobody had.
    nonisolated static func startAnswer(for start: ExecutionStart) -> String {
        let scope = start.started.isEmpty
            ? "the processes the user's checklist selects"
            : start.started.joined(separator: ", ")
        let reclaim = start.isReclaimingSocket
            ? " Atelier is reclaiming the previous run's control socket first, so it comes up a moment late."
            : ""
        return "Starting \(scope).\(reclaim) This does not wait: poll list_processes to watch it come up, "
            + "and read_process_logs when something fails. Nothing will notify you. "
            + "The Execution tab is open but the user's view has not been switched to it — "
            + "use request_attention if you need their eyes."
    }

    func stopExecution(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let controller = execution else {
            return .failure(id: request.id, ExecutionFailure.notAvailable.localizedDescription)
        }
        do {
            let wasRunning = try await controller.stopExecution(in: workstreamID)
            return .success(
                id: request.id,
                .text(wasRunning ? "Stopped this workstream's dev stack." : "Nothing was running.")
            )
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }
}
