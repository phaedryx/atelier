// ABOUTME: Builds the environment an unattended process-compose phase runs with.
// ABOUTME: The same variables a terminal surface gets, so one YAML is not two environments.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "phase-environment")

/// The `ATELIER_*` and `ports.yaml` variables `dispose` sees.
///
/// `prepare` and `execute` run in a Ghostty surface, which is handed
/// `Workstream.Environment.variables` when it is created. The unattended phases
/// spawn through `ProcessCompose.PhaseExecutor` instead, and until this existed they inherited
/// nothing but the app's own environment — so the same
/// `execution.process-compose.yaml` ran under two different environments depending on
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
extension ProcessCompose {
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

        /// The child's environment, in three layers: the app's own, then the
        /// workstream's variables, then the login `PATH`.
        ///
        /// The order is the whole content. The workstream's variables go *over* the
        /// inherited ones, so a `ports.yaml` that declares `ATELIER_PORT` means what
        /// the project says rather than what the app happened to launch with. `PATH`
        /// goes last and unconditionally, because it is the one variable the
        /// workstream layer must not be able to set: a phase whose PATH came from a
        /// declaration would resolve tools from somewhere the user never chose, and
        /// nothing in `Workstream.Environment` produces a `PATH` for it to have meant.
        ///
        /// Internal, and taking its base environment as a parameter, so the layering
        /// can be tested without spawning anything or reading the host's real
        /// environment.
        static func childEnvironment(
            workstreamEnvironment: [String: String],
            loginPath: String?,
            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [String: String] {
            var environment = baseEnvironment
            environment.merge(workstreamEnvironment) { _, workstream in workstream }
            // Assigned unconditionally, which is the whole claim above. `if let`
            // left the *workstream's* PATH standing whenever the login-shell
            // lookup failed — the one outcome this layering exists to prevent.
            // With nothing to fall back to, the child gets no PATH rather than a
            // declared one; assigning nil removes the key.
            environment["PATH"] = loginPath ?? baseEnvironment["PATH"]
            return environment
        }

        /// Resolve `ports.yaml` for this worktree, or nothing if it cannot be read.
        ///
        /// A malformed file logs and yields an empty plan rather than refusing to
        /// run the phase. Nobody is watching an unattended phase, so throwing here
        /// would strand a worktree on a YAML error with no visible cause; the
        /// Execution tab is where that error is meant to be read.
        private static func portPlan(projectDirectory: String, worktreePath: String) -> ProcessCompose.PortPlan {
            do {
                guard let config = try ProcessCompose.PortsConfig.load(from: projectDirectory) else { return .empty }
                return ProcessCompose.PortPlan.resolve(config, workingDirectory: worktreePath)
            } catch {
                logger.warning("ports.yaml: \(error.localizedDescription, privacy: .public)")
                return .empty
            }
        }
    }
}
