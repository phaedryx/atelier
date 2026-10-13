// ABOUTME: Builds environment variables injected into workstream terminals.
// ABOUTME: Centralizes ATELIER_* vars, legacy FF_* aliases, and the project's own port declarations.

import Foundation

extension Workstream {
    enum Environment {
        /// Build the environment variables for a workstream's terminal sessions.
        ///
        /// There used to be a `scriptSource` parameter that added `CONDUCTOR_*`,
        /// `EMDASH_*` and `SUPERSET_*` aliases when the project's scripts had been
        /// read from another tool's config file. Those config formats are no longer
        /// read at all, so the aliases had nothing left to be compatible with.
        static func variables(
            workstreamID: UUID,
            projectName: String,
            workstreamName: String,
            projectDirectory: String,
            workingDirectory: String,
            port: Int,
            defaultBranch: String = "main",
            slot: Int? = nil,
            portPlan: ProcessCompose.PortPlan = .empty
        ) -> [String: String] {
            let id = workstreamID.uuidString.lowercased()
            let portString = "\(port)"

            var vars = [
                "ATELIER_WORKSTREAM_ID": id,
                "ATELIER_PROJECT": projectName,
                "ATELIER_WORKSTREAM": workstreamName,
                "ATELIER_PROJECT_DIR": projectDirectory,
                "ATELIER_WORKTREE_DIR": workingDirectory,
                "ATELIER_PORT": portString,
                "ATELIER_DEFAULT_BRANCH": defaultBranch,
            ]

            // Allocated rather than hashed, so it is the one value here a caller
            // cannot recompute from a path; see `Workstream.Slot`. Reserved in
            // `ports.yaml`, so the merge below cannot replace it.
            if let slot {
                vars["ATELIER_SLOT"] = String(slot)
            }

            // Before the FF_ mirror, so a project's own declarations win over
            // Atelier's defaults: a project that wants ATELIER_PORT to mean
            // something specific may say so. These reach every surface, not just
            // process-compose — a port visible only to the run pane is invisible
            // to a test run in a terminal tab.
            vars.merge(portPlan.values) { _, declared in declared }

            // Run scripts that read FF_* live in the user's own repositories, where a
            // rename here cannot reach them, so both spellings are exported.
            // Runs last, over the final ATELIER_* values (including any portPlan
            // override), so FF_* never lags behind a project's own declaration.
            mirrorFF(&vars)

            return vars
        }

        /// The environment for a group coordinator's terminal.
        ///
        /// No workstream id, name, worktree directory or port: the coordinator
        /// has none of them, and exporting empty ones would make a script
        /// believe it was in a worktree. `ATELIER_SURFACE_ID` is the group id
        /// in `uuidString` case, as every other surface id is, while
        /// `ATELIER_GROUP_ID` is lowercased like `ATELIER_WORKSTREAM_ID`.
        static func coordinatorVariables(
            groupID: UUID,
            groupName: String,
            projectName: String,
            projectDirectory: String,
            defaultBranch: String
        ) -> [String: String] {
            var vars = [
                "ATELIER_PROJECT": projectName,
                "ATELIER_PROJECT_DIR": projectDirectory,
                "ATELIER_DEFAULT_BRANCH": defaultBranch,
                "ATELIER_GROUP_ID": groupID.uuidString.lowercased(),
                "ATELIER_GROUP": groupName,
                "ATELIER_SURFACE_ID": groupID.uuidString,
            ]
            mirrorFF(&vars)
            return vars
        }

        /// Adds an `FF_` spelling of every `ATELIER_` variable.
        private static func mirrorFF(_ vars: inout [String: String]) {
            for (key, value) in Array(vars) {
                guard let suffix = key.stripping(prefix: "ATELIER_") else { continue }
                vars["FF_" + suffix] = value
            }
        }
    }
}

private extension String {
    /// Returns the remainder after `prefix`, or nil when the string doesn't start with it.
    func stripping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
