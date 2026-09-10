// ABOUTME: Persists the most recent verification run and the check selection.
// ABOUTME: Only the latest run, because its stamp is what the tab needs on return.

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
            guard let data = try? JSONEncoder().encode(run) else { return }
            UserDefaults.standard.set(data, forKey: key(for: run.workstreamID))
        }

        static func clear(for workstreamID: UUID) {
            UserDefaults.standard.removeObject(forKey: key(for: workstreamID))
        }
    }

    // MARK: - Selection

    private static let selectionKeyPrefix = "atelier.verifySelection."

    static func selectionKey(for workstreamID: UUID) -> String {
        selectionKeyPrefix + workstreamID.uuidString.lowercased()
    }

    /// Which checks a run should start. Empty means all of them, matching what
    /// `up -n verify` does when given no names — and matching
    /// `ProcessCompose.TableModel.selected(for:)`, whose convention the shared
    /// checklist depends on.
    static func selected(for workstreamID: UUID) -> [String] {
        UserDefaults.standard.stringArray(forKey: selectionKey(for: workstreamID)) ?? []
    }

    static func setSelected(_ names: [String], for workstreamID: UUID) {
        if names.isEmpty {
            UserDefaults.standard.removeObject(forKey: selectionKey(for: workstreamID))
        } else {
            UserDefaults.standard.set(names, forKey: selectionKey(for: workstreamID))
        }
    }
}
