// ABOUTME: Allocates the small dense per-workstream integer exported as ATELIER_SLOT.
// ABOUTME: The one piece of allocation state Atelier keeps; ports stay hashed and stateless.

import Foundation

extension Workstream {
    /// A per-project integer for resources that need a small dense index rather
    /// than a port — a Redis DB number above all, which has sixteen values, so
    /// the DJB2 hash behind `ATELIER_PORT` would collide within a handful of
    /// worktrees.
    ///
    /// Unlike a port this is a function of the *sibling set*, not of one path,
    /// so it cannot be recomputed where an environment is assembled: it is
    /// decided once, when `Workstream.Launcher` mints the workstream, stored on
    /// the record, and carried to each call site the way `id` is. Slots start at
    /// 1, leaving 0 to the project's own checkout and anything run outside
    /// Atelier. There is no upper bound; a consumer with a ceiling enforces it.
    ///
    /// A slot is held while its directory exists, not while its record does.
    /// Detaching a workstream retires the slot into `Project.retiredSlots`
    /// rather than freeing it: remove leaves the dev stack running, and purge
    /// runs `dispose` *after* detach, so either would otherwise hand slot n to a
    /// new workstream while something still uses it.
    enum Slot {
        static func lowestFree(held: Set<Int>) -> Int {
            var candidate = 1
            while held.contains(candidate) {
                candidate += 1
            }
            return candidate
        }

        static func held(workstreams: [Workstream], retired: [String: Int]?) -> Set<Int> {
            Set(workstreams.compactMap(\.slot)).union(retired.map { Array($0.values) } ?? [])
        }

        /// The spelling a path is retired under and looked up by, so adoption
        /// finds a slot whatever form `git worktree list` reports the path in.
        static func key(for path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }

        /// Gives every workstream a distinct valid slot, and drops any retired
        /// entry a live workstream also holds.
        ///
        /// Pure and order-determined, because `ProjectStore.load` is called from
        /// three places that never compare notes: two loads of the same blob must
        /// hand out the same slots before either result is saved.
        @discardableResult
        static func backfill(_ project: inout Project) -> Bool {
            var changed = false
            var taken = Set<Int>()
            var unassigned: [Int] = []
            for index in project.workstreams.indices {
                if let slot = project.workstreams[index].slot, slot >= 1, !taken.contains(slot) {
                    taken.insert(slot)
                } else {
                    unassigned.append(index)
                }
            }
            // A live workstream outranks a retired entry: the collision means an
            // adoption reclaimed the slot and `claim` never ran.
            if let retired = project.retiredSlots {
                let kept = retired.filter { !taken.contains($0.value) }
                if kept.count != retired.count {
                    project.retiredSlots = kept.isEmpty ? nil : kept
                    changed = true
                }
                taken.formUnion(kept.values)
            }
            for index in unassigned {
                let slot = lowestFree(held: taken)
                project.workstreams[index].slot = slot
                taken.insert(slot)
                changed = true
            }
            return changed
        }

        /// Removes a workstream and retires its slot in the same mutation, so
        /// there is no moment when the slot belongs to neither.
        ///
        /// Freed outright, not retired, when there is no path or the path is the
        /// project's own directory or checkout. No current path creates such a
        /// workstream — Adopt is not offered on the main worktree — but `isMain`
        /// has failed open before, and a slot retired under a directory that
        /// never disappears would never be released.
        static func detach(_ workstreamID: UUID, from project: inout Project) {
            guard let index = project.workstreams.firstIndex(where: { $0.id == workstreamID }) else { return }
            let workstream = project.workstreams.remove(at: index)
            guard let slot = workstream.slot, let path = workstream.worktreePath else { return }
            // `canonicalPath`, not `key(for:)`, for the same reason
            // `Archiver.destroyableWorktreePath` uses it: a project registered
            // through a symlink and a path git reported resolved are one
            // directory under two spellings, which is exactly how `isMain`
            // fails open.
            let canonical = path.canonicalPath
            guard canonical != project.directory.canonicalPath,
                  canonical != project.checkout.canonicalPath else { return }
            var retired = project.retiredSlots ?? [:]
            retired[key(for: path)] = slot
            project.retiredSlots = retired
        }

        /// Drops the retired entry a newly appended workstream took over. A
        /// fresh allocation never takes a retired slot, so this only ever
        /// matters for adoption.
        static func claim(_ workstream: Workstream, in project: inout Project) {
            guard let slot = workstream.slot, let retired = project.retiredSlots else { return }
            let kept = retired.filter { $0.value != slot }
            guard kept.count != retired.count else { return }
            project.retiredSlots = kept.isEmpty ? nil : kept
        }

        /// Releases retired slots whose directory is gone — after a purge's
        /// `git worktree remove`, or a removed worktree the user deleted by hand.
        @discardableResult
        static func sweep(_ project: inout Project, exists: (String) -> Bool) -> Bool {
            guard let retired = project.retiredSlots else { return false }
            let kept = retired.filter { exists($0.key) }
            guard kept.count != retired.count else { return false }
            project.retiredSlots = kept.isEmpty ? nil : kept
            return true
        }
    }
}
