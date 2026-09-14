// ABOUTME: The per-check result a Verification row renders, and where it is persisted.
// ABOUTME: One blob per workstream, accumulated by check name across runs.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "verification-check-store")

extension Verification {
    /// One check's most recent result, whichever run produced it.
    ///
    /// **Separate from `Verification.CheckResult` on purpose.** A `CheckResult` is a row
    /// *within* one run and is meaningful only beside that run's other rows; this is the
    /// latest answer for one name, and the run it came from is a field rather than its
    /// container. Rows in the Verification tab come from the project's declared checks and
    /// are filled from these, so running `rspec` alone no longer erases `rubocop`'s result
    /// — which is exactly what it did while `Verification.Store`'s single latest `Run` was
    /// the only thing a row could read.
    struct CheckRecord: Equatable, Codable {
        let name: String
        var state: CheckResult.State
        var duration: TimeInterval?
        var output: String?
        /// Whether `output` is only the tail of a longer log. Means "there was more at
        /// capture time", never "more can be fetched": the control server holding the
        /// full log is torn down when the run seals.
        var outputTruncated: Bool
        /// `Git.Operations.diffFingerprint` of the run that produced this record.
        ///
        /// Per record rather than per run, because checks now complete at different
        /// moments and one run-level staleness banner would be wrong for most rows. `""`
        /// means "not captured yet" and never "no diff" — `verificationRecordIsStale`
        /// reads it that way, and a real fingerprint is always `head|count|digest`.
        var stamp: String
        /// The run this result came from. What `check_verification` resolves, and the
        /// idempotence key `Runner.recordCompletion` uses to fire exactly once per check
        /// per run.
        var runID: String
        var completedAt: Date
    }

    /// Every check's latest result for one workstream, in UserDefaults beside the run.
    ///
    /// **One key per workstream holding a `[String: CheckRecord]`, not one key per
    /// check.** A key per check would put a user-authored process name into a defaults
    /// key, and would leave the purge path enumerating keys it cannot know the names of.
    enum CheckStore {
        private static let prefix = "atelier.verifyChecks."

        static func key(for workstreamID: UUID) -> String {
            prefix + workstreamID.uuidString.lowercased()
        }

        static func records(for workstreamID: UUID) -> [String: CheckRecord] {
            guard let data = UserDefaults.standard.data(forKey: key(for: workstreamID)) else {
                return [:]
            }
            do {
                return try JSONDecoder().decode([String: CheckRecord].self, from: data)
            } catch {
                // Dropped rather than surfaced, the same ruling `Store.latest` makes: a
                // blob written by a build whose model has since changed is a stale
                // convenience, and failing to decode one must not break the tab.
                logger.warning(
                    "Discarding undecodable verification check records: \(error.localizedDescription, privacy: .public)"
                )
                return [:]
            }
        }

        static func save(_ records: [String: CheckRecord], for workstreamID: UUID) {
            do {
                let data = try JSONEncoder().encode(records)
                UserDefaults.standard.set(data, forKey: key(for: workstreamID))
            } catch {
                // Leaves the store holding the prior results, which the tab renders as
                // current: worth logging audibly so that staleness is not silent.
                logger.warning(
                    "Failed to encode verification check records: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        /// Drops a workstream's per-check results.
        ///
        /// `Workstream.Archiver.clearWorkstreamState` is its production caller, beside
        /// `Store.clear` — the key outlives a purged workstream otherwise.
        static func clear(for workstreamID: UUID) {
            UserDefaults.standard.removeObject(forKey: key(for: workstreamID))
        }
    }
}
