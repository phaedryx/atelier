// ABOUTME: Persists the most recent verification run.
// ABOUTME: Only the latest, because its stamp is what the tab needs on return.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "verification-store")

extension Verification {
    /// The last run per workstream, in UserDefaults beside the other
    /// per-workstream keys.
    ///
    /// Only the latest is kept. History would need a policy for how much to
    /// keep and would be read by nothing: the tab shows one run, and
    /// `check_verification` resolving an older id is worth less than a store
    /// that cannot grow without bound.
    enum Store {
        private static let prefix = "atelier.verifyRun."

        static func key(for workstreamID: UUID) -> String {
            prefix + workstreamID.uuidString.lowercased()
        }

        static func latest(for workstreamID: UUID) -> Verification.Run? {
            guard let data = UserDefaults.standard.data(forKey: key(for: workstreamID)) else {
                return nil
            }
            do {
                return try JSONDecoder().decode(Verification.Run.self, from: data)
            } catch {
                // A run written by a build whose model has since changed is
                // dropped, not surfaced: a stale result is a convenience, and
                // failing to decode one must not break the tab.
                logger.warning("Discarding undecodable verification run: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        static func save(_ run: Verification.Run) {
            do {
                let data = try JSONEncoder().encode(run)
                UserDefaults.standard.set(data, forKey: key(for: run.workstreamID))
            } catch {
                // A failure to encode a run (e.g. NaN in duration) leaves the
                // store holding a stale prior result, which the tab renders as
                // that workstream's latest: worth logging audibly so that stale
                // state is not silent.
                logger.warning("Failed to encode verification run: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Drops a workstream's stored run. `Workstream.Archiver.purge` is its
        /// production caller — the key outlives the workstream otherwise — and
        /// it is called last there, after the verify teardown that makes the run
        /// loop seal, because `save` writes this same key. Still its only
        /// caller: `IPC.VerificationRunnerBridge` reads `latest` — that is how
        /// a run id stays resolvable across a restart — and clears nothing.
        static func clear(for workstreamID: UUID) {
            UserDefaults.standard.removeObject(forKey: key(for: workstreamID))
        }
    }
}
