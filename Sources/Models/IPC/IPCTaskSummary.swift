// ABOUTME: Pure formatting and argument parsing for the task-queue tools.
// ABOUTME: The completion/failure notice, tag parsing, and the sender label — nothing here needs a store or a socket.

import Foundation

extension IPC {
    /// Formatting and bounding for the task-queue tools, mirroring
    /// `VerificationSummary`'s split: the wording and the truncation are
    /// where this feature's bugs live, and none of them need an actor or a
    /// project to pin.
    enum TaskSummary {
        /// The label a task-queue notice arrives from. Not a peer id — there
        /// is nothing inside Atelier for an agent to `send_message` back to,
        /// mirroring `VerificationSummary.sender`.
        static let sender = IPC.Vocabulary.taskSender

        /// Character cap on the two agent-authored fields a notice quotes
        /// (`name`, and a failure's `reason`). Generous next to the fixed
        /// shape of the rest of the message — even at four UTF-8 bytes per
        /// character this stays two orders of magnitude under `IPC.Store`'s
        /// 64KB cap, so unlike `VerificationSummary` (which concatenates an
        /// unbounded *number* of check names) this doesn't need byte-precise
        /// budgeting.
        private static let maxQuotedLength = 300

        // MARK: - Arguments

        /// The tags in a `tags` argument, in the order given, without
        /// duplicates. Empty means no filter. Same parsing convention as
        /// `VerificationSummary.checks(from:)` — an argument is always text
        /// however a model chose to spell a list.
        static func tags(from raw: String?) -> [String] {
            ToolArguments.parseList(raw)
        }

        // MARK: - The completion/failure notice

        /// The notice posted to a task's creator when it completes or fails.
        ///
        /// References the task's path and name only, **never its `content`**
        /// — content is agent-chosen up to 64KB, and CLAUDE.md's own language
        /// applies verbatim: an oversized notice "is lost, silently, exactly
        /// when the agent is waiting for it." Both `path` and `name` are clipped
        /// to `maxQuotedLength` to ensure the notice stays within bounds.
        ///
        /// Its one production caller (`IPC.Service`) only ever passes a task
        /// whose state is `.completed` or `.failed` — the `.pending`/
        /// `.claimed` branch below exists only so the switch is exhaustive.
        static func notice(for task: ProjectTask) -> String {
            let label = "Task \"\(clip(task.path))\" (\(clip(task.name)))"
            switch task.state {
            case let .completed(_, at):
                return "\(label) was completed \(Int(Date().timeIntervalSince(at)))s ago. "
                    + "get_pending_tasks or list_tasks shows what's left."
            case let .failed(_, _, reason):
                return "\(label) failed: \(clip(reason))"
            case .pending, .claimed:
                return "\(label) changed state."
            }
        }

        private static func clip(_ text: String) -> String {
            guard text.count > maxQuotedLength else { return text }
            return String(text.prefix(maxQuotedLength)) + "…"
        }
    }
}
