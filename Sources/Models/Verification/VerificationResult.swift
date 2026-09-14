// ABOUTME: The result model for one verification run and its checks.
// ABOUTME: A run is the set of checks one press started, not a suite.

import Foundation

/// A project's verification checks and their results.
///
/// Declared here because this file owns most of the namespace's members; see
/// CLAUDE.md's namespace rule.
enum Verification {}

extension Verification {
    struct CheckResult: Equatable, Codable, Identifiable {
        let name: String
        var state: State
        var duration: TimeInterval?

        var id: String {
            name
        }

        /// What one check is doing.
        ///
        /// **Seven states, two of which no longer have a producer**, and they are
        /// kept deliberately rather than pruned. `.pending` and `.skipped` came
        /// from process-compose's dependency graph, which checks no longer have —
        /// each one is an independent command. They stay because the glyph table,
        /// the state words and the row's accessibility labels are a fixed set the
        /// UI is specified against, and because a queued or dependency-skipped
        /// check is the obvious next thing this could grow. Nothing may start
        /// *reading* them as reachable.
        enum State: Equatable, Codable {
            case notRun
            case pending
            case running
            case passed
            case failed(Int)
            case skipped
            case stopped
        }
    }

    /// The checks one press started, and what became of them.
    ///
    /// **Not a suite.** Checks run independently, so a run carries no shared
    /// lifetime, no server and no ordering — it exists because
    /// `start_verification` has to answer with something an agent can ask about
    /// later, and "the checks that call started" is that something.
    struct Run: Equatable, Codable, Identifiable {
        let id: String
        let workstreamID: UUID
        let startedAt: Date
        /// `Git.Operations.diffFingerprint` at the moment the press happened.
        /// What makes a later result honest about being stale. A real fingerprint
        /// is always `head|count|digest`; `""` means it was not captured.
        var stamp: String
        var checks: [CheckResult]
        /// True once any check in this run was stopped by hand.
        var wasStopped: Bool

        var isFinished: Bool {
            !checks.contains { $0.state == .running || $0.state == .pending }
        }

        var failedNames: [String] {
            checks.compactMap { check in
                if case .failed = check.state {
                    return check.name
                }
                return nil
            }
        }
    }
}
