// ABOUTME: The result model for one verification run and its checks.
// ABOUTME: Owns the ProcessEntry -> state mapping, where two measured traps live.

import Foundation

/// A run of a project's `verify` namespace and its per-check results.
///
/// Declared here because this file owns most of the namespace's members; see
/// CLAUDE.md's namespace rule.
enum Verification {}

extension Verification {
    struct CheckResult: Equatable, Codable, Identifiable {
        let name: String
        var state: State
        var duration: TimeInterval?
        var output: String?
        /// Whether `output` is only the tail of a longer log.
        ///
        /// A tail cannot reveal how much came before it, so this is set when the
        /// fetch came back at its line limit. The IPC projection ORs it with its
        /// own trimming, so no answer claims to be whole when either side cut
        /// it. Defaulted, so every existing construction site stays valid.
        var outputTruncated: Bool = false

        var id: String {
            name
        }

        /// What one check is doing, as Atelier reports it.
        ///
        /// Reading `exitCode` alone gets this wrong twice, both measured
        /// against process-compose v1.122.0:
        ///
        /// - A `Pending` check (waiting on a `depends_on`) reports
        ///   `is_running: false, exit_code: 0` — byte-identical to a pass.
        /// - A `Skipped` check (its dependency failed, so it never ran) reports
        ///   `exit_code: 1` — a failure it never had.
        ///
        /// So `status` decides the shape and `exitCode` only qualifies
        /// `Completed`, which is reported for a success *and* a failure.
        enum State: Equatable, Codable {
            case notRun
            case pending
            case running
            case passed
            case failed(Int)
            case skipped
            case stopped

            init(entry: ProcessCompose.ProcessEntry) {
                switch entry.status {
                case "Running", "Foreground", "Launching", "Restarting":
                    self = .running
                case "Pending":
                    self = .pending
                case "Skipped":
                    self = .skipped
                case "Completed":
                    self = entry.exitCode == 0 ? .passed : .failed(entry.exitCode)
                default:
                    // A status this build does not know must never become a
                    // pass. Live means running; dead with a non-zero code means
                    // failed; anything else has not run.
                    if entry.isRunning {
                        self = .running
                    } else if entry.exitCode != 0 {
                        self = .failed(entry.exitCode)
                    } else {
                        self = .notRun
                    }
                }
            }
        }
    }

    struct Run: Equatable, Codable, Identifiable {
        let id: String
        let workstreamID: UUID
        let startedAt: Date
        /// `Git.Operations.diffFingerprint` at the moment the run started. What
        /// makes a later result honest about being stale.
        let stamp: String
        var checks: [CheckResult]
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
