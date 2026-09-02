// ABOUTME: Builds environment variables injected into workstream terminals.
// ABOUTME: Centralizes ATELIER_* vars, legacy FF_* aliases, and compatibility aliases for external tools.

import Foundation

enum WorkstreamEnvironment {
    /// Build the environment variables for a workstream's terminal sessions.
    /// When `scriptSource` matches an external tool's config file, compatibility
    /// aliases are added so scripts written for that tool work without modification.
    static func variables(
        workstreamID: UUID,
        projectName: String,
        workstreamName: String,
        projectDirectory: String,
        workingDirectory: String,
        port: Int,
        defaultBranch: String = "main",
        scriptSource: String? = nil,
        portPlan: PortPlan = .empty
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

        // Run scripts that read FF_* live in the user's own repositories, where a
        // rename here cannot reach them. Export both spellings, the same way the
        // CONDUCTOR_/EMDASH_/SUPERSET_ aliases below cover other tools' scripts.
        for (key, value) in Array(vars) {
            guard let suffix = key.stripping(prefix: "ATELIER_") else { continue }
            vars["FF_" + suffix] = value
        }

        switch scriptSource {
        case "conductor.json":
            vars["CONDUCTOR_WORKSPACE_NAME"] = workstreamName
            vars["CONDUCTOR_ROOT_PATH"] = projectDirectory
            vars["CONDUCTOR_WORKSPACE_PATH"] = workingDirectory
            vars["CONDUCTOR_PORT"] = portString
            vars["CONDUCTOR_DEFAULT_BRANCH"] = defaultBranch
        case ".emdash.json":
            vars["EMDASH_TASK_ID"] = id
            vars["EMDASH_TASK_NAME"] = workstreamName
            vars["EMDASH_TASK_PATH"] = workingDirectory
            vars["EMDASH_ROOT_PATH"] = projectDirectory
            vars["EMDASH_PORT"] = portString
            vars["EMDASH_DEFAULT_BRANCH"] = defaultBranch
        case ".superset/config.json":
            vars["SUPERSET_WORKSPACE_NAME"] = workstreamName
            vars["SUPERSET_ROOT_PATH"] = projectDirectory
            vars["SUPERSET_PORT_BASE"] = portString
        default:
            break
        }

        // Last, so a project's own declarations win over Atelier's defaults: a
        // project that wants ATELIER_PORT to mean something specific may say so.
        // These reach every surface, not just process-compose — a port visible
        // only to the run pane is invisible to a test run in a terminal tab.
        vars.merge(portPlan.values) { _, declared in declared }

        return vars
    }
}

private extension String {
    /// Returns the remainder after `prefix`, or nil when the string doesn't start with it.
    func stripping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
