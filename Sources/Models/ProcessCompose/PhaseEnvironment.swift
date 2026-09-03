// ABOUTME: Builds the environment an unattended process-compose phase runs with.
// ABOUTME: The same variables a terminal surface gets, so one YAML is not two environments.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "phase-environment")

/// The `ATELIER_*` and `ports.yaml` variables `bootstrap` and `dispose` see.
///
/// `prepare` and `execute` run in a Ghostty surface, which is handed
/// `Workstream.Environment.variables` when it is created. The unattended phases
/// spawn through `PhaseExecutor` instead, and until this existed they inherited
/// nothing but the app's own environment — so the same
/// `process-compose.yaml` ran under two different environments depending on
/// which namespace was being asked for. Concretely, the documented replacement
/// for the seeding this integration removed,
/// `rsync -rlpt --copy-links "$$ATELIER_PROJECT_DIR/seed-files/" .`, rsynced
/// from `/seed-files/` because `ATELIER_PROJECT_DIR` was unset, and every port
/// a project declared in `ports.yaml` was missing from half its own phases.
///
/// The port plan is resolved here rather than passed in, because neither call
/// site — worktree creation and archive — has one of its own to hand over.
/// `Port.Allocator` is deterministic per worktree and per variable name, so a
/// plan resolved here lands on the same numbers Start does, modulo the liveness
/// probe: both walk forward past a port that happens to be bound at the moment
/// they look, and what is bound differs between worktree creation and Start.
/// A `fixed` port never moves.
enum PhaseEnvironment {
    /// - Parameter defaultBranch: passed in rather than resolved here so this
    ///   spawns no git. Both call sites want the same value the terminal
    ///   surfaces get, which is `Git.Operations.defaultBranch(at:)` — not
    ///   `BaseBranchSetting`, which governs which branch a worktree is *cut
    ///   from* and is a different question.
    static func variables(
        workstreamID: UUID,
        projectName: String,
        workstreamName: String,
        projectDirectory: String,
        worktreePath: String,
        defaultBranch: String
    ) -> [String: String] {
        Workstream.Environment.variables(
            workstreamID: workstreamID,
            projectName: projectName,
            workstreamName: workstreamName,
            projectDirectory: projectDirectory,
            workingDirectory: worktreePath,
            port: Port.Allocator.port(for: worktreePath),
            defaultBranch: defaultBranch,
            portPlan: portPlan(projectDirectory: projectDirectory, worktreePath: worktreePath)
        )
    }

    /// Resolve `ports.yaml` for this worktree, or nothing if it cannot be read.
    ///
    /// A malformed file logs and yields an empty plan rather than refusing to
    /// run the phase. Nobody is watching an unattended phase, so throwing here
    /// would strand a worktree on a YAML error with no visible cause; the
    /// Environment tab is where that error is meant to be read.
    private static func portPlan(projectDirectory: String, worktreePath: String) -> PortPlan {
        do {
            guard let config = try PortsConfig.load(from: projectDirectory) else { return .empty }
            return PortPlan.resolve(config, workingDirectory: worktreePath)
        } catch {
            logger.warning("ports.yaml: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }
}
