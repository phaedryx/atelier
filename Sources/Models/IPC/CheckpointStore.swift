// ABOUTME: One workstream's "where I left off" note, free text, in UserDefaults.
// ABOUTME: One blob per workstream, overwritten wholesale — no version history.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "session-checkpoint-store")

extension IPC {
    /// A workstream's saved checkpoint, and when it was last written.
    struct Checkpoint: Equatable, Codable {
        var content: String
        var updatedAt: Date
    }

    /// Where a workstream's checkpoint lives, in UserDefaults.
    ///
    /// **One key per workstream holding one `Checkpoint`, the same shape
    /// `Verification.CheckStore` uses for per-check results** — a single blob
    /// rather than a key per something-user-authored, which here would have
    /// nothing to be keyed by anyway: a checkpoint is one note, not a
    /// collection.
    ///
    /// **Shared per workstream, not per agent.** Two agents in one
    /// workstream — the Coding Agent and one spawned via `open_agent_tab` —
    /// read and write the same blob. That is a deliberate scope decision, not
    /// an oversight: this is local state for the workstream, not a per-peer
    /// mailbox.
    ///
    /// Not compiled into `AtelierMCP` — `project.yml:198-200` takes only
    /// `IPCProtocol.swift` out of this directory for that target — because
    /// only `IPC.Service` (the app target) ever touches this store.
    enum CheckpointStore {
        private static let prefix = "atelier.sessionCheckpoint."

        /// Mirrors `IPC.Store`'s message cap. That constant is `private` on the
        /// store actor and unreachable from here, so this is a second literal
        /// rather than a shared one — tied to it by this comment instead.
        static let maxContentSize = 65_536

        enum Error: Swift.Error, LocalizedError, Equatable {
            case contentTooLarge

            /// Agent-facing protocol text, not UI: this travels over the wire to
            /// a coding agent, so it is deliberately not localized — the same
            /// rule `IPC.Store.Error` states for its own message.
            var errorDescription: String? {
                switch self {
                case .contentTooLarge:
                    "Checkpoint content exceeds maximum size (64KB)."
                }
            }
        }

        static func key(for workstreamID: UUID) -> String {
            prefix + workstreamID.uuidString.lowercased()
        }

        /// The workstream's checkpoint, or nil if none has ever been saved.
        static func read(for workstreamID: UUID) -> Checkpoint? {
            guard let data = UserDefaults.standard.data(forKey: key(for: workstreamID)) else {
                return nil
            }
            do {
                return try JSONDecoder().decode(Checkpoint.self, from: data)
            } catch {
                // Dropped rather than surfaced, the same ruling `CheckStore.records`
                // makes: a blob written by a build whose model has since changed is
                // a stale convenience, and failing to decode it must not read as a
                // hard failure — it reads as "nothing saved yet."
                logger.warning(
                    "Discarding undecodable session checkpoint: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        /// Overwrites the workstream's checkpoint. Refuses oversized content
        /// outright rather than truncating it — a checkpoint an agent believes
        /// it saved in full is worse than one it is told was refused.
        @discardableResult
        static func save(_ content: String, for workstreamID: UUID) throws -> Checkpoint {
            guard content.utf8.count <= maxContentSize else { throw Error.contentTooLarge }
            let checkpoint = Checkpoint(content: content, updatedAt: Date())
            do {
                let data = try JSONEncoder().encode(checkpoint)
                UserDefaults.standard.set(data, forKey: key(for: workstreamID))
            } catch {
                // Leaves the store holding whatever it held before, which the next
                // read renders as current: worth logging audibly rather than
                // silently keeping stale content.
                logger.warning(
                    "Failed to encode session checkpoint: \(error.localizedDescription, privacy: .public)"
                )
            }
            return checkpoint
        }

        /// Drops a workstream's checkpoint.
        ///
        /// `Workstream.Archiver.clearWorkstreamState` is its production caller,
        /// beside `Verification.CheckStore.clear` and
        /// `ProcessCompose.TableModel.clearSelection` — the key outlives a purged
        /// workstream otherwise. `remove` (which keeps the worktree on disk)
        /// deliberately does not call this, matching the existing rule for the
        /// other two per-workstream keys.
        static func clear(for workstreamID: UUID) {
            UserDefaults.standard.removeObject(forKey: key(for: workstreamID))
        }
    }
}
