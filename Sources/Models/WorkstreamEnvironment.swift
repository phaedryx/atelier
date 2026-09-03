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
            for (key, value) in Array(vars) {
                guard let suffix = key.stripping(prefix: "ATELIER_") else { continue }
                vars["FF_" + suffix] = value
            }

            return vars
        }
    }
}

private extension String {
    /// Returns the remainder after `prefix`, or nil when the string doesn't start with it.
    func stripping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
